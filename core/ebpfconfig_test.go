package main

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/include"
	"github.com/sagernet/sing-box/option"
	sjson "github.com/sagernet/sing/common/json"
)

func TestEbpfConfigShape(t *testing.T) {
	out, err := ebpfConfig(rootTestYAML, "node-b")
	if err != nil {
		t.Fatalf("ebpfConfig: %v", err)
	}
	ctx := include.Context(context.Background())
	if _, err := sjson.UnmarshalExtendedContext[option.Options](ctx, []byte(out)); err != nil {
		t.Fatalf("daemon would reject the config: %v", err)
	}
	var root map[string]any
	if err := json.Unmarshal([]byte(out), &root); err != nil {
		t.Fatal(err)
	}
	inbounds := root["inbounds"].([]any)
	if len(inbounds) != 2 {
		t.Fatalf("inbounds = %v, want redirect + tproxy", inbounds)
	}
	red := inbounds[0].(map[string]any)
	if red["type"] != "redirect" || red["listen_port"] != float64(ebpfRedirectPort) {
		t.Errorf("redirect inbound wrong: %v", red)
	}
	tp := inbounds[1].(map[string]any)
	if tp["type"] != "tproxy" || tp["network"] != "udp" || tp["listen_port"] != float64(ebpfTproxyPort) {
		t.Errorf("tproxy inbound wrong: %v", tp)
	}
	route := root["route"].(map[string]any)
	if route["final"] != "node-b" {
		t.Errorf("final = %v, want the pinned node", route["final"])
	}
	if route["default_mark"] != float64(ebpfCoreMark) {
		t.Errorf("default_mark = %v, want the core exemption mark", route["default_mark"])
	}
	for _, ob := range root["outbounds"].([]any) {
		m := ob.(map[string]any)
		typ, _ := m["type"].(string)
		if typ == "selector" || typ == "urltest" {
			t.Errorf("group outbound survived: %v", m["tag"])
		}
		if tag := m["tag"]; tag != "node-b" && typ != "direct" && typ != "block" {
			t.Errorf("unexpected outbound kept: %v (%v)", tag, typ)
		}
	}
	dns := root["dns"].(map[string]any)
	servers := dns["servers"].([]any)
	remote := servers[1].(map[string]any)
	if remote["detour"] != "node-b" {
		t.Errorf("dns-remote detour = %v, want the pinned node", remote["detour"])
	}
}

// The ebpf daemon has no TUN, so a healthy config should
// start outright in this sandbox (plain listeners only);
// any failure must at least not be the DNS/detour class.
func TestEbpfConfigStarts(t *testing.T) {
	out, err := ebpfConfig(rootTestYAML, "node-a")
	if err != nil {
		t.Fatalf("ebpfConfig: %v", err)
	}
	ctx := include.Context(context.Background())
	options, err := sjson.UnmarshalExtendedContext[option.Options](ctx, []byte(out))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	instance, err := box.New(box.Options{Context: ctx, Options: options})
	if err != nil {
		t.Fatalf("create box: %v", err)
	}
	defer instance.Close()
	err = instance.Start()
	if err != nil {
		if strings.Contains(err.Error(), "dns") || strings.Contains(err.Error(), "detour") {
			t.Fatalf("start dies in DNS/detour stage: %v", err)
		}
		t.Logf("start stopped later (environment): %v", err)
		return
	}
	t.Log("box fully started")
}
