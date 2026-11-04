package main

import (
	"context"
	"strings"
	"testing"

	"github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/include"
	"github.com/sagernet/sing-box/option"
	sjson "github.com/sagernet/sing/common/json"
)

// Reproduction for the on-device 0.54 failure: the daemon's
// box.Start died in dns-transport start. A healthy config
// gets past that stage; a later environment failure (no
// /dev/net/tun, no CAP_NET_ADMIN in this sandbox) is fine
// and distinguishable by its message.
func TestRootConfigStartsPastDNS(t *testing.T) {
	out, err := rootTunConfig(rootTestYAML, "node-a", false, nil, nil)
	if err != nil {
		t.Fatalf("rootTunConfig: %v", err)
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
			t.Fatalf("start still dies in DNS/detour stage: %v", err)
		}
		t.Logf("start got past DNS, stopped later (environment): %v", err)
		return
	}
	t.Log("box fully started")
}
