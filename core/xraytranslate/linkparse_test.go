package xraytranslate

import (
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
)

func parseOne(t *testing.T, link string) map[string]any {
	t.Helper()
	out, err := ParseShareLinks(link)
	if err != nil {
		t.Fatalf("parse %q: %v", link, err)
	}
	var res struct {
		Entries []map[string]any `json:"entries"`
		Skipped int              `json:"skipped"`
	}
	if err := json.Unmarshal([]byte(out), &res); err != nil {
		t.Fatalf("result json: %v", err)
	}
	if len(res.Entries) != 1 {
		t.Fatalf("entries = %v", res.Entries)
	}
	return res.Entries[0]
}

func TestParseLinksAndTranslate(t *testing.T) {
	vmessJSON := `{"v":"2","ps":"VM-WS","add":"192.0.2.30","port":"443","id":"11111111-2222-3333-4444-555555555555","aid":"0","scy":"auto","net":"ws","path":"/vm","host":"cdn.example.com","tls":"tls","sni":"sni.example.com"}`
	links := []string{
		"vless://11111111-2222-3333-4444-555555555555@192.0.2.10:443?security=reality&sni=www.apple.com&fp=chrome&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=abcd1234&flow=xtls-rprx-vision&type=tcp#NTT-REALITY",
		"vmess://" + base64.StdEncoding.EncodeToString([]byte(vmessJSON)),
		"trojan://pw123@192.0.2.40:443?sni=tr.example.com#TR-1",
		"ss://" + base64.StdEncoding.EncodeToString([]byte("aes-256-gcm:sspw")) + "@192.0.2.50:8388#SS-1",
		"hysteria2://authpw@192.0.2.60:443?sni=hy.example.com&obfs=salamander&obfs-password=obfspw&up=50&down=200#HY2-1",
		"wireguard://AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=@192.0.2.70:51820?publickey=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=&address=10.0.0.2/32&mtu=1280#WG-1",
	}
	yamlText := ""
	names := []string{}
	for _, link := range links {
		entry := parseOne(t, link)
		entryJSON, _ := json.Marshal(entry)
		out, err := UpsertNode([]byte(yamlText), string(entryJSON), "")
		if err != nil {
			t.Fatalf("upsert %q: %v", link, err)
		}
		yamlText = out
		names = append(names, entry["name"].(string))
	}
	res, err := Translate([]byte(yamlText), Options{})
	if err != nil {
		t.Fatalf("translate imported: %v", err)
	}
	if len(res.Nodes) != 6 {
		t.Fatalf("nodes = %+v skipped = %+v", res.Nodes, res.Skipped)
	}
	want := []string{"NTT-REALITY", "VM-WS", "TR-1", "SS-1", "HY2-1", "WG-1"}
	for i, w := range want {
		if res.Nodes[i].Name != w {
			t.Fatalf("node %d = %q, want %q (all: %+v)", i, res.Nodes[i].Name, w, res.Nodes)
		}
	}
	// The hy2 entry must carry the obfs password through translation.
	if !strings.Contains(res.Configs["HY2-1"], "salamander") {
		t.Fatalf("hy2 config lost obfs: %s", res.Configs["HY2-1"])
	}
	if !strings.Contains(res.Configs["NTT-REALITY"], "reality") {
		t.Fatalf("vless config lost reality: %s", res.Configs["NTT-REALITY"])
	}
}

func TestParseBlob(t *testing.T) {
	blob := base64.StdEncoding.EncodeToString([]byte(
		"trojan://pw@192.0.2.1:443#B1\ntrojan://pw@192.0.2.2:443#B2\n"))
	out, err := ParseShareLinks(blob)
	if err != nil {
		t.Fatalf("blob: %v", err)
	}
	var res struct {
		Entries []map[string]any `json:"entries"`
	}
	if err := json.Unmarshal([]byte(out), &res); err != nil {
		t.Fatal(err)
	}
	if len(res.Entries) != 2 {
		t.Fatalf("entries = %v", res.Entries)
	}
	if _, err := ParseShareLinks("hello world"); err == nil {
		t.Fatal("garbage should error")
	}
}
