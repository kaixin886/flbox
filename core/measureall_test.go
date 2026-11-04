package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// Combined measurement: one instance, three outbounds, each
// probed through its own account. The middle outbound is a
// SOCKS door to a dead port, so its probe must fail while its
// neighbours succeed - if the per-account routing were broken
// and everything left through the first outbound, the middle
// result would wrongly succeed and this test would catch it.
func TestXrayMeasureAllRoutesPerOutbound(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()

	deadSocks := `{"outbounds":[{"protocol":"socks","settings":{"servers":[{"address":"127.0.0.1","port":1}]}}]}`
	configs := []string{freedomConfig, deadSocks, freedomConfig}
	raw, _ := json.Marshal(configs)
	out, err := xrayMeasureAll(string(raw), srv.URL+"/generate_204")
	if err != nil {
		t.Fatalf("measureAll failed: %v", err)
	}
	var results []int64
	if err := json.Unmarshal([]byte(out), &results); err != nil {
		t.Fatalf("result is not a json array: %v (%q)", err, out)
	}
	if len(results) != 3 {
		t.Fatalf("want 3 results, got %v", results)
	}
	if results[0] < 0 || results[2] < 0 {
		t.Errorf("freedom outbounds should measure, got %v", results)
	}
	if results[1] != -1 {
		t.Errorf("dead-socks outbound should fail, got %v", results)
	}
}

// A config the loader cannot even parse must fail the whole
// combined setup (the caller then falls back to per-node
// measurement for the chunk) instead of silently dropping the
// node from the results.
func TestXrayMeasureAllBadConfigFailsSetup(t *testing.T) {
	bad := `{"outbounds":[{"protocol":"no-such-protocol"}]}`
	raw, _ := json.Marshal([]string{freedomConfig, bad})
	done := make(chan struct{})
	go func() {
		defer close(done)
		_, err := xrayMeasureAll(string(raw), "http://127.0.0.1:1/generate_204")
		if err == nil {
			t.Error("expected a setup error for a bogus protocol")
		}
	}()
	select {
	case <-done:
	case <-time.After(30 * time.Second):
		t.Fatal("measureAll setup did not return")
	}
}

// The per-node config the translator emits carries sections
// the combined builder must survive: routing with geosite
// references in particular is trimmed before the outbounds are
// merged, so a chunk full of them still builds.
func TestXrayMeasureAllTrimsGeoSections(t *testing.T) {
	withGeo := strings.Replace(
		freedomConfig,
		`"outbounds"`,
		`"routing":{"rules":[{"type":"field","domain":["geosite:cn"],"outboundTag":"proxy"}]},"outbounds"`,
		1,
	)
	if withGeo == freedomConfig {
		t.Skip("freedom fixture has no outbounds key to anchor on")
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()
	raw, _ := json.Marshal([]string{withGeo})
	out, err := xrayMeasureAll(string(raw), srv.URL+"/generate_204")
	if err != nil {
		t.Fatalf("measureAll with geo sections failed: %v", err)
	}
	var results []int64
	if err := json.Unmarshal([]byte(out), &results); err != nil || len(results) != 1 {
		t.Fatalf("want one result, got %q (err %v)", out, err)
	}
}
