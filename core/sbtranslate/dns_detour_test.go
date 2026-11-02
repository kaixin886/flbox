package sbtranslate

import (
	"encoding/json"
	"testing"
)

// Regression for the batch-5 device failure: pinning a translated
// nameserver to the plain direct outbound makes sing-box refuse Start
// ("detour to an empty direct outbound makes no sense"). The typed
// servers build their dialer without the default outbound, so an unset
// detour already dials directly; the field must stay absent.
func TestDNSServersHaveNoDetour(t *testing.T) {
	const profile = `
mixed-port: 7890
mode: rule
dns:
  enable: true
  nameserver:
    - https://dns.alidns.com/dns-query
    - 223.5.5.5
proxies:
  - name: NODE
    type: vless
    server: 203.0.113.10
    port: 443
    uuid: 11111111-2222-3333-4444-555555555555
    network: tcp
    tls: true
    flow: xtls-rprx-vision
    servername: www.apple.com
    client-fingerprint: chrome
    reality-opts:
      public-key: CQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
      short-id: 34c44918
proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - NODE
      - DIRECT
rules:
  - MATCH,PROXY
`
	cfg, err := ParseClash([]byte(profile))
	if err != nil {
		t.Fatal(err)
	}
	out, err := Translate(cfg)
	if err != nil {
		t.Fatal(err)
	}
	var root map[string]any
	if err := json.Unmarshal(out, &root); err != nil {
		t.Fatal(err)
	}
	dns, ok := root["dns"].(map[string]any)
	if !ok {
		t.Fatalf("no dns block in translated config: %s", out)
	}
	servers, ok := dns["servers"].([]any)
	if !ok || len(servers) == 0 {
		t.Fatalf("no dns servers in translated config: %s", out)
	}
	for _, raw := range servers {
		srv, ok := raw.(map[string]any)
		if !ok {
			t.Fatalf("dns server is not an object: %v", raw)
		}
		switch srv["type"] {
		case "udp", "https", "tls":
			if detour, present := srv["detour"]; present {
				t.Errorf("dns server %v (%v) detour = %v, want the field absent", srv["tag"], srv["type"], detour)
			}
		}
	}
}

func TestBuiltinNameTagMapping(t *testing.T) {
	for name, want := range map[string]string{"DIRECT": "direct", "REJECT": "block", "PROXY": "PROXY", "NODE": "NODE"} {
		if got := TagForName(name); got != want {
			t.Errorf("TagForName(%q) = %q, want %q", name, got, want)
		}
		if got := NameForTag(want); got != name {
			t.Errorf("NameForTag(%q) = %q, want %q", want, got, name)
		}
	}
}
