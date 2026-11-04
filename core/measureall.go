package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/xtls/xray-core/common/serial"
	xcore "github.com/xtls/xray-core/core"
	coreserial "github.com/xtls/xray-core/infra/conf/serial"
	"golang.org/x/net/proxy"
)

// measureAllPort is the loopback door into a combined
// measurement instance. Chunks run one at a time inside the
// test process, so one fixed port serves every chunk; if a
// wedged predecessor still holds it, the combined Start fails
// and the caller falls back to per-node measurement for that
// chunk instead of corrupting results.
const measureAllPort = 20199

// xrayMeasureAll measures a chunk of nodes the way the Clash
// family does: ONE core instance holds every outbound of the
// chunk, and each node is probed through its own outbound -
// no per-node instance is ever created or torn down.
//
// Builds 0.45-0.52 established what the per-node shape costs
// on the user's phone: dozens of throwaway instances per run
// wedge or accumulate somewhere below the Dart layer, and the
// back half of every run degrades into inflated delays and
// false timeouts whatever process hosts them. A resident
// instance removes instance churn from the equation entirely;
// the only per-node work left is a connection, exactly like
// ordinary proxied traffic.
//
// Addressing one outbound among many uses stock Xray surface:
// the combined instance has a single SOCKS inbound with one
// account per node, and a routing rule per account sends that
// account's traffic to its outbound tag. The probe for node i
// is an HTTP client whose dialer opens a SOCKS tunnel as
// account i. The instance is created and started once, the
// probes run in parallel (bounded at eight), and teardown is
// handed to the background closer like any other instance.
//
// configsJSON is a JSON array of the chunk's per-node config
// strings (the same buildConfig output the per-node path
// consumes). The result is a JSON array of delays in the same
// order, -1 per failed node. A non-nil error means the
// combined instance itself could not be built or started -
// the caller then falls back to measuring the chunk per-node.
func xrayMeasureAll(configsJSON string, url string) (string, error) {
	if url == "" {
		url = "http://www.gstatic.com/generate_204"
	}
	var configs []string
	if err := json.Unmarshal([]byte(configsJSON), &configs); err != nil {
		return "", fmt.Errorf("measureAll configs not a json array: %w", err)
	}
	if len(configs) == 0 {
		return "[]", nil
	}
	outbounds := make([]any, 0, len(configs))
	accounts := make([]any, 0, len(configs))
	rules := make([]any, 0, len(configs))
	for i, cj := range configs {
		var cfg map[string]any
		if err := json.Unmarshal([]byte(cj), &cfg); err != nil {
			return "", fmt.Errorf("measure config %d is not json: %w", i, err)
		}
		trimMeasureSections(cfg)
		obs, _ := cfg["outbounds"].([]any)
		if len(obs) == 0 {
			return "", fmt.Errorf("measure config %d has no outbounds", i)
		}
		ob, _ := obs[0].(map[string]any)
		if ob == nil {
			return "", fmt.Errorf("measure config %d outbound is not an object", i)
		}
		tag := fmt.Sprintf("out-%d", i)
		ob["tag"] = tag
		outbounds = append(outbounds, ob)
		user := fmt.Sprintf("u%d", i)
		accounts = append(accounts, map[string]any{"user": user, "pass": "flbox"})
		rules = append(rules, map[string]any{
			"type":        "field",
			"user":        []any{user},
			"outboundTag": tag,
		})
	}
	combined := map[string]any{
		"log": map[string]any{"loglevel": "warning", "access": "none"},
		"inbounds": []any{
			map[string]any{
				"tag":      "measure-in",
				"listen":   "127.0.0.1",
				"port":     measureAllPort,
				"protocol": "socks",
				"settings": map[string]any{
					"auth":     "password",
					"accounts": accounts,
					"udp":      false,
				},
			},
		},
		"routing": map[string]any{
			"domainStrategy": "AsIs",
			"rules":          rules,
		},
		"outbounds": outbounds,
	}
	raw, err := json.Marshal(combined)
	if err != nil {
		return "", err
	}
	config, err := coreserial.LoadJSONConfig(strings.NewReader(string(raw)))
	if err != nil {
		return "", fmt.Errorf("combined config load failed: %w", err)
	}
	// Keep only the apps the combined shape needs: both
	// proxyman halves (the SOCKS door is a real inbound this
	// time), the dispatcher, the router (the per-account rules
	// live there) and the log. Stats and policy stay out, as in
	// the per-node path.
	var essential []*serial.TypedMessage
	for _, app := range config.App {
		switch app.Type {
		case "xray.app.proxyman.InboundConfig",
			"xray.app.proxyman.OutboundConfig",
			"xray.app.dispatcher.Config",
			"xray.app.router.Config",
			"xray.app.log.Config":
			essential = append(essential, app)
		}
	}
	config.App = essential
	inst, err := xcore.New(config)
	if err != nil {
		return "", fmt.Errorf("combined instance create failed: %w", err)
	}
	defer enqueueClose(inst)
	if err := inst.Start(); err != nil {
		return "", fmt.Errorf("combined instance start failed: %w", err)
	}

	results := make([]int64, len(configs))
	var wg sync.WaitGroup
	sem := make(chan struct{}, 8)
	for i := range configs {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			results[idx] = probeViaSocks(idx, url)
		}(i)
	}
	wg.Wait()
	out, err := json.Marshal(results)
	if err != nil {
		return "", err
	}
	return string(out), nil
}

// probeViaSocks measures one node of the combined instance:
// it dials the instance's SOCKS door as that node's account,
// so the router sends the probe out through that node's
// outbound, and runs the usual two-attempt probe over the
// tunnel.
func probeViaSocks(idx int, url string) int64 {
	dialer, err := proxy.SOCKS5(
		"tcp",
		fmt.Sprintf("127.0.0.1:%d", measureAllPort),
		&proxy.Auth{User: fmt.Sprintf("u%d", idx), Password: "flbox"},
		proxy.Direct,
	)
	if err != nil {
		return -1
	}
	tr := &http.Transport{
		TLSHandshakeTimeout: 6 * time.Second,
		DisableKeepAlives:   false,
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			return dialer.Dial(network, addr)
		},
	}
	defer tr.CloseIdleConnections()
	client := &http.Client{Transport: tr, Timeout: 12 * time.Second}
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	ms, err := probeURL(ctx, client, url)
	if err != nil {
		return -1
	}
	return ms
}
