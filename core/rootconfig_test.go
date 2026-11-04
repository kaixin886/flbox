package main

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/sagernet/sing-box/include"
	"github.com/sagernet/sing-box/option"
	sjson "github.com/sagernet/sing/common/json"
)

const rootTestYAML = `
mixed-port: 7890
proxies:
  - name: node-a
    type: ss
    server: a.example.com
    port: 8388
    cipher: aes-128-gcm
    password: pw-a
  - name: node-b
    type: ss
    server: 203.0.113.7
    port: 8389
    cipher: aes-128-gcm
    password: pw-b
proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - node-a
      - node-b
rules:
  - MATCH,PROXY
`

func TestRootTunConfigShape(t *testing.T) {
	out, err := rootTunConfig(rootTestYAML, "node-b", true, nil, []string{"com.example.app"})
	if err != nil {
		t.Fatalf("rootTunConfig: %v", err)
	}
	// The daemon must be able to parse it as sing-box options.
	ctx := include.Context(context.Background())
	if _, err := sjson.UnmarshalExtendedContext[option.Options](ctx, []byte(out)); err != nil {
		t.Fatalf("daemon would reject the config: %v", err)
	}
	var root map[string]any
	if err := json.Unmarshal([]byte(out), &root); err != nil {
		t.Fatal(err)
	}
	inbounds := root["inbounds"].([]any)
	if len(inbounds) != 1 {
		t.Fatalf("inbounds = %v", inbounds)
	}
	tun := inbounds[0].(map[string]any)
	if tun["type"] != "tun" || tun["auto_route"] != true || tun["stack"] != "gvisor" {
		t.Errorf("tun inbound wrong: %v", tun)
	}
	if _, ok := tun["strict_route"]; ok {
		t.Error("strict_route must stay off (0.56 self-capture fix)")
	}
	excl, _ := tun["route_exclude_address"].([]any)
	if len(excl) != 2 || excl[0] != "223.5.5.5/32" || excl[1] != "203.0.113.7/32" {
		t.Errorf("route excludes = %v, want bootstrap + node-b IP", excl)
	}
	if got := tun["exclude_package"]; got == nil || len(got.([]any)) != 1 {
		t.Errorf("exclude_package missing: %v", tun)
	}
	route := root["route"].(map[string]any)
	if route["final"] != "PROXY" {
		t.Errorf("final = %v, want the group", route["final"])
	}
	if route["auto_detect_interface"] != true {
		t.Errorf("auto_detect_interface must be on (0.56 self-capture fix)")
	}
	if _, ok := route["rule_set"]; ok {
		t.Error("rule_set must be stripped in global stage")
	}
	// The selector must default to the chosen node.
	for _, ob := range root["outbounds"].([]any) {
		m := ob.(map[string]any)
		if m["tag"] == "PROXY" && m["default"] != "node-b" {
			t.Errorf("selector default = %v, want node-b", m["default"])
		}
	}
	// node-b's server is an IP: no bootstrap DNS rule needed,
	// but the bootstrap + remote servers must exist.
	dns := root["dns"].(map[string]any)
	if dns["final"] != "dns-remote" {
		t.Errorf("dns final = %v", dns["final"])
	}
	if _, ok := dns["rules"]; ok {
		t.Errorf("no dns rule expected for an IP server, got %v", dns["rules"])
	}
}

func TestRootTunConfigBootstrapForDomainServer(t *testing.T) {
	out, err := rootTunConfig(rootTestYAML, "node-a", false, []string{"com.only.me"}, nil)
	if err != nil {
		t.Fatalf("rootTunConfig: %v", err)
	}
	if !strings.Contains(out, "a.example.com") || !strings.Contains(out, "dns-bootstrap") {
		t.Errorf("bootstrap rule for the node domain missing")
	}
	var root map[string]any
	_ = json.Unmarshal([]byte(out), &root)
	tun := root["inbounds"].([]any)[0].(map[string]any)
	if got := tun["include_package"]; got == nil {
		t.Errorf("include_package missing: %v", tun)
	}
	if len(tun["address"].([]any)) != 1 {
		t.Errorf("ipv6 off should give one address: %v", tun["address"])
	}
}

func TestRootTunConfigUnknownNode(t *testing.T) {
	if _, err := rootTunConfig(rootTestYAML, "nope", false, nil, nil); err == nil {
		t.Error("expected an error for a node outside the profile")
	}
}
