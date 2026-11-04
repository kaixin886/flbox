package xraytranslate

import (
	"strings"
	"testing"
)

const shareTestYAML = `proxies:
  - name: NTT-REALITY
    type: vless
    server: 192.0.2.10
    port: 443
    uuid: 11111111-2222-3333-4444-555555555555
    flow: xtls-rprx-vision
    tls: true
    servername: www.apple.com
    client-fingerprint: chrome
    reality-opts:
      public-key: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
      short-id: abcd1234
  - name: HY2-HOP
    type: hysteria2
    server: 192.0.2.60
    port: 443
    password: authpw
    sni: hy.example.com
    obfs: salamander
    obfs-password: obfspw
    ports: 20000-30000
`

func TestShareLinkVlessReality(t *testing.T) {
	link, err := ShareLinkFor(shareTestYAML, "NTT-REALITY")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		"vless://11111111-2222-3333-4444-555555555555@192.0.2.10:443",
		"security=reality", "pbk=AAAA", "sid=abcd1234",
		"flow=xtls-rprx-vision", "sni=www.apple.com", "#NTT-REALITY",
	} {
		if !strings.Contains(link, want) {
			t.Errorf("link %q missing %q", link, want)
		}
	}
	// The share link must come back through our own importer.
	entry := parseOne(t, link)
	if entry["server"] != "192.0.2.10" || entry["name"] != "NTT-REALITY" {
		t.Errorf("round trip entry = %v", entry)
	}
}

func TestShareLinkHy2AndHopTranslate(t *testing.T) {
	link, err := ShareLinkFor(shareTestYAML, "HY2-HOP")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		"hysteria2://authpw@192.0.2.60:443",
		"mport=20000-30000", "obfs=salamander", "sni=hy.example.com",
	} {
		if !strings.Contains(link, want) {
			t.Errorf("link %q missing %q", link, want)
		}
	}
	entry := parseOne(t, link)
	if entry["ports"] != "20000-30000" {
		t.Fatalf("round trip ports = %v", entry["ports"])
	}
	res, err := Translate([]byte(shareTestYAML), Options{})
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, n := range res.Nodes {
		if n.Name == "HY2-HOP" {
			found = true
		}
	}
	if !found {
		t.Fatalf("HY2-HOP missing from %+v skipped %+v", res.Nodes, res.Skipped)
	}
}

func TestHy2UdpHopInConfig(t *testing.T) {
	res, err := Translate([]byte(shareTestYAML), Options{})
	if err != nil {
		t.Fatal(err)
	}
	cfg := res.Configs["HY2-HOP"]
	if !strings.Contains(cfg, "udpHop") ||
		!strings.Contains(cfg, "20000-30000") {
		t.Fatalf("config lacks udpHop:\n%s", cfg)
	}
}
