package xraytranslate

import (
	"encoding/json"
	"strings"
	"testing"
)

const editYAML = `
proxies:
  - name: A-VLESS
    type: vless
    server: 192.0.2.1
    port: 443
    uuid: 11111111-2222-3333-4444-555555555555
    tls: true
  - name: B-SS
    type: ss
    server: 192.0.2.2
    port: 8388
    cipher: aes-256-gcm
    password: pw
rules:
  - MATCH,PROXY
`

func TestNodeDetail(t *testing.T) {
	out, err := NodeDetail([]byte(editYAML), "B-SS")
	if err != nil {
		t.Fatalf("detail: %v", err)
	}
	var m map[string]any
	if err := json.Unmarshal([]byte(out), &m); err != nil {
		t.Fatalf("detail json: %v", err)
	}
	if m["cipher"] != "aes-256-gcm" || m["port"] != float64(8388) {
		t.Fatalf("detail = %v", m)
	}
	if _, err := NodeDetail([]byte(editYAML), "NOPE"); err == nil {
		t.Fatal("detail of missing node should error")
	}
}

func TestUpsertAppendAndTranslate(t *testing.T) {
	entry := `{"name":"C-HY2","type":"hysteria2","server":"192.0.2.3","port":443,"password":"auth","sni":"example.com","up":50}`
	out, err := UpsertNode([]byte(editYAML), entry, "")
	if err != nil {
		t.Fatalf("upsert: %v", err)
	}
	if !strings.Contains(out, "MATCH,PROXY") {
		t.Fatalf("rules lost in rewrite:\n%s", out)
	}
	res, err := Translate([]byte(out), Options{})
	if err != nil {
		t.Fatalf("translate after upsert: %v", err)
	}
	if len(res.Nodes) != 3 {
		t.Fatalf("nodes = %+v", res.Nodes)
	}
	detail, err := NodeDetail([]byte(out), "C-HY2")
	if err != nil {
		t.Fatalf("detail after upsert: %v", err)
	}
	var m map[string]any
	if err := json.Unmarshal([]byte(detail), &m); err != nil {
		t.Fatal(err)
	}
	if m["up"] != float64(50) || m["port"] != float64(443) {
		t.Fatalf("upserted detail = %v", m)
	}
}

func TestUpsertReplaceRename(t *testing.T) {
	entry := `{"name":"A-RENAMED","type":"vless","server":"192.0.2.9","port":8443,"uuid":"11111111-2222-3333-4444-555555555555","tls":true}`
	out, err := UpsertNode([]byte(editYAML), entry, "A-VLESS")
	if err != nil {
		t.Fatalf("upsert: %v", err)
	}
	if strings.Contains(out, "A-VLESS") {
		t.Fatalf("old entry survived rename:\n%s", out)
	}
	res, err := Translate([]byte(out), Options{})
	if err != nil {
		t.Fatalf("translate: %v", err)
	}
	if len(res.Nodes) != 2 || res.Nodes[0].Name != "A-RENAMED" {
		t.Fatalf("nodes = %+v", res.Nodes)
	}
}

func TestUpsertIntoEmptyDoc(t *testing.T) {
	entry := `{"name":"ONLY","type":"trojan","server":"192.0.2.5","port":443,"password":"pw"}`
	out, err := UpsertNode(nil, entry, "")
	if err != nil {
		t.Fatalf("upsert into empty: %v", err)
	}
	res, err := Translate([]byte(out), Options{})
	if err != nil {
		t.Fatalf("translate: %v", err)
	}
	if len(res.Nodes) != 1 || res.Nodes[0].Name != "ONLY" {
		t.Fatalf("nodes = %+v", res.Nodes)
	}
}

func TestDeleteNode(t *testing.T) {
	out, err := DeleteNode([]byte(editYAML), "A-VLESS")
	if err != nil {
		t.Fatalf("delete: %v", err)
	}
	res, err := Translate([]byte(out), Options{})
	if err != nil {
		t.Fatalf("translate: %v", err)
	}
	if len(res.Nodes) != 1 || res.Nodes[0].Name != "B-SS" {
		t.Fatalf("nodes = %+v", res.Nodes)
	}
	if _, err := DeleteNode([]byte(editYAML), "NOPE"); err == nil {
		t.Fatal("delete of missing node should error")
	}
}

func TestFilterNodes(t *testing.T) {
	out, err := FilterNodes([]byte(editYAML), "", "B-.*")
	if err != nil {
		t.Fatalf("filter: %v", err)
	}
	res, err := Translate([]byte(out), Options{})
	if err != nil {
		t.Fatalf("translate: %v", err)
	}
	if len(res.Nodes) != 1 || res.Nodes[0].Name != "A-VLESS" {
		t.Fatalf("nodes = %+v", res.Nodes)
	}
	out, err = FilterNodes([]byte(editYAML), "A-", "")
	if err != nil {
		t.Fatalf("filter keep: %v", err)
	}
	res, _ = Translate([]byte(out), Options{})
	if len(res.Nodes) != 1 || res.Nodes[0].Name != "A-VLESS" {
		t.Fatalf("keep nodes = %+v", res.Nodes)
	}
	if _, err := FilterNodes([]byte(editYAML), "[", ""); err == nil {
		t.Fatal("bad regex should error")
	}
}
