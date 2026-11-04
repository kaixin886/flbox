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
	"sync"
	"time"

	corenet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/serial"
	xcore "github.com/xtls/xray-core/core"
	coreserial "github.com/xtls/xray-core/infra/conf/serial"
)

// measureMu serializes instance CREATION - load, create,
// start - across all concurrent measure calls; the probe runs
// in parallel and teardown runs on a background closer (see
// closeQueue below), so neither waits on the other. The
// controlled comparison across builds is unambiguous: every
// FlBox build whose test instances were created serially
// (0.42's node swapping, 0.43's lock-held starts) ran the full
// list without crashing, and every build that created
// instances concurrently (0.44's listening instances, 0.45's
// first cut of this design) died partway through the same
// subscription on the same phone. v2rayNG survives the same
// native shape because its test service runs in a separate
// ":tasks" process (manifest), so a native abort there never
// takes the UI down - and even they serialize measurements
// globally for untrimmable configs.
var measureMu sync.Mutex

// closeQueue feeds a single background goroutine that closes
// finished test instances one at a time. Closes used to run on
// the calling worker under measureMu, and that was the poison
// in 0.47-0.49: every run on the user's phone wedged at
// exactly 23 posted results with the process still alive -
// one instance's Close deadlocked, ate the mutex, and queued
// every later lifecycle call behind it forever; results whose
// probes had already succeeded never posted either, because
// their own deferred closes were stuck in the same queue (the
// missing results were scattered, not a clean prefix). A
// hanging Close now stalls only the closer goroutine: leaked
// instances pile up harmlessly in a throwaway process, closes
// stay serialized among themselves, and measurement never
// waits on teardown.
var closeQueue = make(chan *xcore.Instance, 128)

func init() {
	go func() {
		for inst := range closeQueue {
			inst.Close()
		}
	}()
}

func enqueueClose(inst *xcore.Instance) {
	if inst == nil {
		return
	}
	select {
	case closeQueue <- inst:
	default:
		// The closer is wedged and the queue is full; hand the
		// instance to a fire-and-forget goroutine rather than
		// block a measurement on it.
		go inst.Close()
	}
}

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
//   - The instance is created and measured inside this one
//     call; teardown is handed to a serialized background
//     closer (see closeQueue) so a hanging Close can never
//     wedge the run. Earlier designs kept throwaway instances
//     alive
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
	// The lifecycle - parse, create, start - runs under
	// measureMu (see its comment); the probe below does not.
	measureMu.Lock()
	config, err := coreserial.LoadJSONConfig(strings.NewReader(string(raw)))
	var inst *xcore.Instance
	if err == nil {
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
		inst, err = xcore.New(config)
		if err == nil {
			err = inst.Start()
		}
	}
	measureMu.Unlock()
	if err != nil {
		enqueueClose(inst)
		return -1, fmt.Errorf("test instance setup failed: %w", err)
	}
	defer func() { enqueueClose(inst) }()

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
