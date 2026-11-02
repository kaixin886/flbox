package sbtranslate

import (
	"context"
	"strings"
	"testing"

	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/include"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/common/json"
	"github.com/sagernet/sing/service"
)

// Regression: an airport-style url-test group with a one-hour interval
// made sing-box refuse to Start ("interval must be less or equal than
// idle_timeout") because the translator never raised idle_timeout.
// Inbounds are stripped before Start: the sandbox cannot bind sockets,
// and the urltest validation under test runs in the outbound phase.
func TestURLTestLongIntervalStarts(t *testing.T) {
	yaml := `
proxies:
  - name: N1
    type: vless
    server: 128.242.109.233
    port: 8444
    uuid: f35bebd3-8221-430b-9061-ef0a244fcd23
    network: tcp
    tls: true
    flow: xtls-rprx-vision
    servername: www.apple.com
    client-fingerprint: chrome
    reality-opts:
      public-key: fPEkxD-B7sAmraXVZssbmF6CdWJ5D_8kLHdyGaVAvT0
      short-id: f1b2891b0b7326f1
proxy-groups:
  - name: AUTO
    type: url-test
    url: http://www.gstatic.com/generate_204
    interval: 3600
    proxies: [N1]
rules:
  - MATCH,AUTO
`
	cfg, err := ParseClash([]byte(yaml))
	if err != nil {
		t.Fatal(err)
	}
	out, err := Translate(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(out), `"idle_timeout": "3600s"`) {
		t.Fatalf("idle_timeout not raised:\n%s", out)
	}
	ctx := include.Context(context.Background())
	opts, err := json.UnmarshalExtendedContext[option.Options](ctx, out)
	if err != nil {
		t.Fatal(err)
	}
	opts.Inbounds = nil
	inst, err := box.New(box.Options{Context: service.ExtendContext(ctx), Options: opts})
	if err != nil {
		t.Fatal(err)
	}
	if err := inst.Start(); err != nil {
		t.Fatalf("start: %v", err)
	}
	_ = inst.Close()
}
