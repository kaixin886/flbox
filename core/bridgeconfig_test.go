package main

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/sagernet/sing-box/include"
	"github.com/sagernet/sing-box/option"
	sjson "github.com/sagernet/sing/common/json"
)

func TestBridgeConfigsShape(t *testing.T) {
	out, err := bridgeConfigs(rootTestYAML, "node-b", true, 1, []int{10123, 10456})
	if err != nil {
		t.Fatalf("bridgeConfigs: %v", err)
	}
	var envelope map[string]string
	if err := json.Unmarshal([]byte(out), &envelope); err != nil {
		t.Fatal(err)
	}
	ctx := include.Context(context.Background())
	if _, err := sjson.UnmarshalExtendedContext[option.Options](ctx, []byte(envelope["core"])); err != nil {
		t.Fatalf("daemon would reject the core config: %v", err)
	}
	var core map[string]any
	if err := json.Unmarshal([]byte(envelope["core"]), &core); err != nil {
		t.Fatal(err)
	}
	inbounds := core["inbounds"].([]any)
	if len(inbounds) != 1 {
		t.Fatalf("core inbounds = %v, want one socks inbound", inbounds)
	}
	socks := inbounds[0].(map[string]any)
	if socks["type"] != "socks" || socks["listen_port"] != float64(bridgeSocksPort) {
		t.Errorf("socks inbound wrong: %v", socks)
	}
	var bridge map[string]any
	if err := json.Unmarshal([]byte(envelope["bridge"]), &bridge); err != nil {
		t.Fatal(err)
	}
	if bridge["socksPort"] != float64(bridgeSocksPort) ||
		bridge["bridgePort"] != float64(bridgeListenPort) ||
		bridge["enableDnsHijack"] != true ||
		bridge["enableIpv6"] != true ||
		bridge["pinnedObjectDir"] != bridgePinnedDir {
		t.Errorf("bridge config wrong: %v", bridge)
	}
	policy := bridge["policy"].(map[string]any)
	if policy["mode"] != float64(1) || len(policy["uids"].([]any)) != 2 {
		t.Errorf("bridge policy wrong: %v", policy)
	}
	if _, err := bridgeFileConfig(false, 3, nil); err == nil {
		t.Errorf("mode 3 must be rejected")
	}
}
