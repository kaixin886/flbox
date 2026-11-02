package main

import (
	"encoding/json"
	"fmt"
	"net"
	"sync"
	"time"

	xcore "github.com/xtls/xray-core/core"
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

func xrayTranslate(clashYAML string) (string, error) {
	result, err := xraytranslate.Translate([]byte(clashYAML))
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
// whether the listener is actually reachable in-process.
func xrayStart(configJSON string) error {
	xMu.Lock()
	defer xMu.Unlock()
	if xInst != nil {
		xInst.Close()
		xInst = nil
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
