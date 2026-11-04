package xraytranslate

import (
	"strings"
	"testing"
)

func TestConvertSingboxJSON(t *testing.T) {
	doc := `{
	  "outbounds": [
	    {"type": "vless", "tag": "SB-VLESS", "server": "192.0.2.10", "server_port": 443,
	     "uuid": "11111111-2222-3333-4444-555555555555", "flow": "xtls-rprx-vision",
	     "tls": {"enabled": true, "server_name": "www.apple.com",
	             "reality": {"enabled": true, "public_key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "short_id": "abcd1234"},
	             "utls": {"enabled": true, "fingerprint": "chrome"}}},
	    {"type": "hysteria2", "tag": "SB-HY2", "server": "192.0.2.11", "server_port": 443,
	     "password": "authpw", "obfs": {"type": "salamander", "password": "obfspw"},
	     "up_mbps": 50, "down_mbps": 200,
	     "tls": {"enabled": true, "server_name": "hy.example.com"}},
	    {"type": "selector", "tag": "PROXY", "outbounds": ["SB-VLESS"]},
	    {"type": "direct", "tag": "direct"}
	  ],
	  "endpoints": [
	    {"type": "wireguard", "tag": "SB-WG", "address": ["10.0.0.2/32"], "private_key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
	     "peers": [{"address": "192.0.2.12", "port": 51820, "public_key": "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=", "allowed_ips": ["0.0.0.0/0"]}]}
	  ]
	}`
	yamlText, kind, err := ConvertImport(doc)
	if err != nil {
		t.Fatalf("convert: %v", err)
	}
	if kind != "singbox-json" {
		t.Fatalf("kind = %q", kind)
	}
	res, err := Translate([]byte(yamlText), Options{})
	if err != nil {
		t.Fatalf("translate: %v", err)
	}
	if len(res.Nodes) != 3 {
		t.Fatalf("nodes = %+v skipped = %+v", res.Nodes, res.Skipped)
	}
	if !strings.Contains(res.Configs["SB-HY2"], "salamander") {
		t.Fatalf("hy2 obfs lost: %s", res.Configs["SB-HY2"])
	}
}

func TestConvertXrayJSON(t *testing.T) {
	doc := `{
	  "outbounds": [
	    {"tag": "XR-VLESS", "protocol": "vless",
	     "settings": {"vnext": [{"address": "192.0.2.20", "port": 443,
	       "users": [{"id": "11111111-2222-3333-4444-555555555555", "flow": "xtls-rprx-vision", "encryption": "none"}]}]},
	     "streamSettings": {"network": "tcp", "security": "reality",
	       "realitySettings": {"serverName": "www.apple.com", "fingerprint": "chrome",
	         "publicKey": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "shortId": "abcd1234"}}},
	    {"tag": "XR-HY2", "protocol": "hysteria",
	     "settings": {"version": 2, "address": "192.0.2.21", "port": 443},
	     "streamSettings": {"network": "hysteria", "security": "tls",
	       "tlsSettings": {"serverName": "www.apple.com", "alpn": ["h3"],
	         "pinnedPeerCertSha256": "AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99"},
	       "hysteriaSettings": {"version": 2, "auth": "authpw"},
	       "finalmask": {"udp": [{"type": "salamander", "settings": {"password": "obfspw"}}],
	                     "quicParams": {"brutalUp": "50 Mbps", "brutalDown": "200 Mbps"}}}},
	    {"tag": "proxy-fallback", "protocol": "freedom", "settings": {}}
	  ]
	}`
	yamlText, kind, err := ConvertImport(doc)
	if err != nil {
		t.Fatalf("convert: %v", err)
	}
	if kind != "xray-json" {
		t.Fatalf("kind = %q", kind)
	}
	res, err := Translate([]byte(yamlText), Options{})
	if err != nil {
		t.Fatalf("translate: %v", err)
	}
	if len(res.Nodes) != 2 {
		t.Fatalf("nodes = %+v skipped = %+v", res.Nodes, res.Skipped)
	}
	hy2 := res.Configs["XR-HY2"]
	if !strings.Contains(hy2, "pinnedPeerCertSha256") || !strings.Contains(hy2, "salamander") {
		t.Fatalf("hy2 pin/obfs lost: %s", hy2)
	}
}

func TestConvertLinksAndYAML(t *testing.T) {
	yamlText, kind, err := ConvertImport(
		"trojan://pw@192.0.2.1:443#L1\ntrojan://pw@192.0.2.2:443#L2\n")
	if err != nil {
		t.Fatalf("links convert: %v", err)
	}
	if kind != "links" {
		t.Fatalf("kind = %q", kind)
	}
	res, err := Translate([]byte(yamlText), Options{})
	if err != nil || len(res.Nodes) != 2 {
		t.Fatalf("nodes = %+v err = %v", res.Nodes, err)
	}
	orig := "proxies:\n  - name: A\n    type: trojan\n    server: 192.0.2.1\n    port: 443\n    password: pw\n"
	out, kind, err := ConvertImport(orig)
	if err != nil || kind != "yaml" || out != orig {
		t.Fatalf("yaml passthrough: kind=%q err=%v same=%v", kind, err, out == orig)
	}
}
