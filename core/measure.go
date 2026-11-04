package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"time"

	corenet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/serial"
	xcore "github.com/xtls/xray-core/core"
	coreserial "github.com/xtls/xray-core/infra/conf/serial"
)

// xrayMeasureDelay measures one node's real latency in a single
// self-contained call, following the design v2rayNG ships
// (AndroidLibXrayLite's MeasureOutboundDelay, read from source
// when 0.44's approach failed on the user's phone):
//
//   - The node's config is reduced to its essentials inside the
//     core: no inbound handlers at all, and of the parsed app
//     sections only proxyman-outbound, dispatcher and log are
//     kept. Routing, DNS, stats and policy never initialize, so
//     no geo data is loaded and no port is ever opened.
//   - The probe runs IN-PROCESS: an HTTP client whose dialer is
//     the instance itself (core.Dial), so the request leaves
//     through the instance's default outbound - the node under
//     test. Nothing listens, nothing is probed from outside.
//   - The instance is created, measured and closed inside this
//     one call. Earlier designs kept throwaway instances alive
//     across FFI calls in a registry while other instances
//     started and stopped around them (0.43/0.44); on the phone
//     that died partway through the list. v2rayNG only ever
//     parallelizes this trimmed, self-contained shape (their
//     full-config measurements are serialized natively because,
//     in their words, parallel teardown can abort the probe
//     process), and so does this port.
//
// Two attempts are made and the better time wins, mirroring the
// reference implementation.
func xrayMeasureDelay(configJSON, url string) (int64, error) {
	// Keep the throwaway instance out of the shared error log:
	// many of them measuring at once would interleave writes.
	var cfg map[string]any
	if err := json.Unmarshal([]byte(configJSON), &cfg); err != nil {
		return -1, fmt.Errorf("measure config is not json: %w", err)
	}
	cfg["log"] = map[string]any{"loglevel": "warning", "access": "none"}
	// Trim at the JSON level too (v2rayNG trims in its config
	// builder before the native call, and its native side then
	// drops the same sections again): in this core version the
	// JSON loader resolves geosite references while PARSING the
	// routing and DNS sections, so leaving them in would make
	// every measure load the geo data files - or fail outright
	// when the asset directory is not in play. The App filter
	// below remains as the second line of defense.
	delete(cfg, "inbounds")
	delete(cfg, "routing")
	delete(cfg, "dns")
	delete(cfg, "fakedns")
	delete(cfg, "stats")
	delete(cfg, "policy")
	raw, err := json.Marshal(cfg)
	if err != nil {
		return -1, err
	}
	config, err := coreserial.LoadJSONConfig(strings.NewReader(string(raw)))
	if err != nil {
		return -1, fmt.Errorf("config load error: %w", err)
	}
	config.Inbound = nil
	var essential []*serial.TypedMessage
	for _, app := range config.App {
		switch app.Type {
		case "xray.app.proxyman.OutboundConfig",
			"xray.app.dispatcher.Config",
			"xray.app.log.Config":
			essential = append(essential, app)
		}
	}
	config.App = essential

	inst, err := xcore.New(config)
	if err != nil {
		return -1, fmt.Errorf("instance creation failed: %w", err)
	}
	if err := inst.Start(); err != nil {
		return -1, fmt.Errorf("startup failed: %w", err)
	}
	defer inst.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	return measureInstDelay(ctx, inst, url)
}

// measureInstDelay probes url through inst's default outbound
// and returns the best of two attempts in milliseconds.
func measureInstDelay(ctx context.Context, inst *xcore.Instance, url string) (int64, error) {
	if inst == nil {
		return -1, errors.New("core instance is nil")
	}
	if url == "" {
		url = "http://www.gstatic.com/generate_204"
	}
	tr := &http.Transport{
		TLSHandshakeTimeout: 6 * time.Second,
		DisableKeepAlives:   false,
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			dest, err := corenet.ParseDestination(fmt.Sprintf("%s:%s", network, addr))
			if err != nil {
				return nil, err
			}
			return xcore.Dial(ctx, inst, dest)
		},
	}
	defer tr.CloseIdleConnections()
	client := &http.Client{Transport: tr, Timeout: 12 * time.Second}

	var minDuration int64 = -1
	success := false
	var lastErr error
	const attempts = 2
	for i := 0; i < attempts; i++ {
		select {
		case <-ctx.Done():
			if !success {
				return -1, ctx.Err()
			}
			return minDuration, nil
		default:
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		if err != nil {
			lastErr = fmt.Errorf("failed to create HTTP request: %w", err)
			continue
		}
		start := time.Now()
		resp, err := client.Do(req)
		if err != nil {
			lastErr = err
			continue
		}
		_, copyErr := io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
		if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusNoContent {
			lastErr = fmt.Errorf("invalid status: %s", resp.Status)
			continue
		}
		if copyErr != nil {
			lastErr = fmt.Errorf("failed to read response body: %w", copyErr)
			continue
		}
		duration := time.Since(start).Milliseconds()
		if !success || duration < minDuration {
			minDuration = duration
		}
		success = true
	}
	if !success {
		return -1, lastErr
	}
	return minDuration, nil
}
