package main

import (
	"encoding/json"
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
