package main

import (
	"encoding/json"
	"sync"

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

func xrayStart(configJSON string) error {
	xMu.Lock()
	defer xMu.Unlock()
	if xInst != nil {
		xInst.Close()
		xInst = nil
	}
	inst, err := xcore.StartInstance("json", []byte(configJSON))
	if err != nil {
		return err
	}
	if err := inst.Start(); err != nil {
		inst.Close()
		return err
	}
	xInst = inst
	return nil
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
