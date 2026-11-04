package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/xtls/xray-core/common/platform"
	xcore "github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/features/stats"
	_ "github.com/xtls/xray-core/main/distro/all"

	"flbox/core/xraytranslate"
)

// Xray engine lifecycle: a single embedded instance, started with a
// standalone JSON config produced by xraytranslate. Trial scope runs
// alongside the sing-box service without sharing state.
var (
	xMu   sync.Mutex
	xInst *xcore.Instance
)

func xrayVersion() string {
	return xcore.Version()
}

// xAssetDir is where geoip.dat / geosite.dat live for rule mode. It
// is captured from the log path (the app documents directory) because
// that is where the app downloads the rule databases.
var xAssetDir string

func xrayTranslate(clashYAML, mode, logPath string) (string, error) {
	if logPath != "" {
		xAssetDir = filepath.Dir(logPath)
	}
	result, err := xraytranslate.Translate([]byte(clashYAML), xraytranslate.Options{
		VPN:     strings.HasPrefix(mode, "vpn"),
		Rules:   strings.HasSuffix(mode, ":rules"),
		LogPath: logPath,
	})
	if err != nil {
		return "", err
	}
	raw, err := json.Marshal(result)
	if err != nil {
		return "", err
	}
	return string(raw), nil
}

func xrayTranslateAll(clashYAML, logPath string) (string, error) {
	res, err := xraytranslate.TranslateAll([]byte(clashYAML), logPath)
	if err != nil {
		return "", err
	}
	raw, err := json.Marshal(res)
	if err != nil {
		return "", err
	}
	return string(raw), nil
}

func init() {
	// One un-loadable node must never poison a whole-profile
	// speed test (a removed Xray field in a single airport
	// node used to fail every node's test at once, because
	// the combined config is loaded as a whole). TranslateAll
	// drops outbounds the real loader rejects.
	xraytranslate.OutboundCheck = func(outbound map[string]any) error {
		raw, err := json.Marshal(map[string]any{
			"inbounds": []any{
				map[string]any{
					"listen":   "127.0.0.1",
					"port":     20199,
					"protocol": "mixed",
				},
			},
			"outbounds": []any{outbound},
		})
		if err != nil {
			return err
		}
		_, err = xcore.LoadConfig("json", strings.NewReader(string(raw)))
		return err
	}
}

var xReport string

// xrayStart starts the instance (StartInstance already starts it; an
// extra Start call is a second start of every feature) and then probes
// its own inbound from inside the process, so the log page can show
// whether the listener is actually reachable in-process. For VPN
// configs the TUN fd from the Android VpnService is handed to the tun
// inbound through its environment variable before the instance is
// created (the inbound reads it at construction time).
func xrayStart(configJSON string, tunFd int) error {
	xMu.Lock()
	defer xMu.Unlock()
	if xInst != nil {
		xInst.Close()
		xInst = nil
	}
	if tunFd > 0 {
		os.Setenv(platform.TunFdKey, strconv.Itoa(tunFd))
	} else {
		os.Unsetenv(platform.TunFdKey)
	}
	if xAssetDir != "" {
		// Rule mode resolves geosite:/geoip: entries from these files.
		os.Setenv(platform.AssetLocation, xAssetDir)
	}
	inst, err := xcore.StartInstance("json", []byte(configJSON))
	if err != nil {
		xReport = fmt.Sprintf("start error: %v", err)
		return err
	}
	xInst = inst
	conn, derr := net.DialTimeout("tcp", "127.0.0.1:7890", 2*time.Second)
	if derr != nil {
		xReport = fmt.Sprintf("started, but in-process dial to 127.0.0.1:7890 failed: %v", derr)
	} else {
		conn.Close()
		xReport = "started, in-process dial to 127.0.0.1:7890 OK"
	}
	return nil
}

func xrayStatus() string {
	xMu.Lock()
	defer xMu.Unlock()
	running := xInst != nil
	return fmt.Sprintf("xray %s · running=%v · %s", xcore.Version(), running, xReport)
}

// xrayTraffic returns the proxy outbound's cumulative byte counters as
// JSON, for the dashboard's live traffic readout.
func xrayTraffic() string {
	xMu.Lock()
	defer xMu.Unlock()
	var up, down int64
	if xInst != nil {
		if feat := xInst.GetFeature(stats.ManagerType()); feat != nil {
			if mgr, ok := feat.(stats.Manager); ok {
				if c := mgr.GetCounter("outbound>>>proxy>>>traffic>>>uplink"); c != nil {
					up = c.Value()
				}
				if c := mgr.GetCounter("outbound>>>proxy>>>traffic>>>downlink"); c != nil {
					down = c.Value()
				}
			}
		}
	}
	return fmt.Sprintf(`{"up":%d,"down":%d}`, up, down)
}

func xrayStop() error {
	xMu.Lock()
	defer xMu.Unlock()
	if xInst == nil {
		return nil
	}
	err := xInst.Close()
	xInst = nil
	return err
}

// Transient per-node test instances for the bulk speed test.
// Each test runs a node's OWN single-node config - the shape
// daily connections prove - as a throwaway instance on a
// private port, without touching the main instance: a live VPN
// session (whose core listens on 7890 and is fed by the
// sing-box forwarder) keeps running while tests fly, nothing
// needs restoring afterwards, and several tests run in
// parallel. This replaced two failed designs: one combined
// instance holding every outbound at once (flash-crashed the
// app on the user's phone), and swapping the main instance
// node by node (worked, but took the better part of a minute
// and locked the user out meanwhile).
//
// Two speed rules learned from the first cut of this design
// (0.43, still slow on the user's phone):
//   - The registry mutex guards ONLY the map. Holding it across
//     StartInstance serialized every start, so the "parallel"
//     workers queued behind the single most expensive step.
//   - A latency probe needs no routing, DNS, stats or policy:
//     with no routing section the instance sends everything to
//     its first (proxy) outbound, which is exactly the node
//     under test. Rule-mode configs carry geosite/geoip routing
//     and split DNS; starting one instance per node made every
//     start load the geo data files and build matchers - the
//     dominant per-node cost, paid dozens of times per run.
var (
	testMu    sync.Mutex
	testInsts = map[int]*xcore.Instance{}
)

func xrayTestStart(configJSON string, port int) error {
	var cfg map[string]any
	if err := json.Unmarshal([]byte(configJSON), &cfg); err != nil {
		return fmt.Errorf("test config is not json: %w", err)
	}
	inbounds, ok := cfg["inbounds"].([]any)
	if !ok || len(inbounds) == 0 {
		return errors.New("test config has no inbound")
	}
	first, ok := inbounds[0].(map[string]any)
	if !ok {
		return errors.New("test config inbound malformed")
	}
	first["port"] = port
	// Detach the log from the shared error file: many instances
	// writing one file concurrently would interleave and fight.
	cfg["log"] = map[string]any{"loglevel": "warning", "access": "none"}
	// Slim the config down to what a probe needs (see the speed
	// rules above): inbound plus the node's outbound. Dropping
	// the DNS section also drops its geo references, so no asset
	// directory is consulted at all.
	delete(cfg, "routing")
	delete(cfg, "dns")
	delete(cfg, "stats")
	delete(cfg, "policy")
	raw, err := json.Marshal(cfg)
	if err != nil {
		return err
	}
	// StartInstance runs OUTSIDE the registry lock so parallel
	// workers really do start their instances at the same time.
	inst, err := xcore.StartInstance("json", raw)
	if err != nil {
		return err
	}
	testMu.Lock()
	old := testInsts[port]
	testInsts[port] = inst
	testMu.Unlock()
	if old != nil {
		old.Close()
	}
	return nil
}

func xrayTestStop(port int) error {
	testMu.Lock()
	inst := testInsts[port]
	delete(testInsts, port)
	testMu.Unlock()
	if inst == nil {
		return nil
	}
	return inst.Close()
}
