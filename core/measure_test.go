package main

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
)

// The bulk speed test measures each node through one
// self-contained core call (v2rayNG's MeasureOutboundDelay
// design): trimmed config, no inbounds, in-process probe. A
// freedom-only config against a local 204 server exercises the
// whole path - load, trim, create, start, dial through the
// instance, close - with no external network involved.
const freedomConfig = `{"outbounds":[{"protocol":"freedom","tag":"proxy"}]}`

func test204Server(t *testing.T) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	t.Cleanup(srv.Close)
	return srv
}

func TestXrayMeasureDelayDirect(t *testing.T) {
	srv := test204Server(t)
	ms, err := xrayMeasureDelay(freedomConfig, srv.URL+"/generate_204")
	if err != nil {
		t.Fatalf("measure: %v", err)
	}
	if ms < 0 {
		t.Fatalf("measure returned %d ms against a local server", ms)
	}
}

// Routing/DNS sections referencing geo lists that do not exist
// must never reach instance startup: the measure path drops
// every app section except proxyman-outbound, dispatcher and
// log. If a bogus geosite survived, Start would fail resolving
// it instead of measuring.
func TestXrayMeasureDelayDropsGeoSections(t *testing.T) {
	srv := test204Server(t)
	cfg := `{
		"routing": {
			"domainStrategy": "IPIfNonMatch",
			"rules": [{"type": "field", "domain": ["geosite:definitely-not-a-real-list"], "outboundTag": "proxy"}]
		},
		"dns": {
			"servers": [{"address": "223.5.5.5", "domains": ["geosite:definitely-not-a-real-list"]}]
		},
		"outbounds": [{"protocol": "freedom", "tag": "proxy"}]
	}`
	ms, err := xrayMeasureDelay(cfg, srv.URL+"/generate_204")
	if err != nil {
		t.Fatalf("measure with bogus geo sections: %v", err)
	}
	if ms < 0 {
		t.Fatalf("measure returned %d ms against a local server", ms)
	}
}

// The Dart side runs eight measure calls concurrently. Their
// instance lifecycles interleave completely inside the core, so
// require a batch of simultaneous calls to all land cleanly.
func TestXrayMeasureDelayConcurrent(t *testing.T) {
	srv := test204Server(t)
	url := srv.URL + "/generate_204"
	const n = 6
	errs := make([]error, n)
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			ms, err := xrayMeasureDelay(freedomConfig, url)
			if err == nil && ms < 0 {
				err = fmt.Errorf("negative delay %d", ms)
			}
			errs[i] = err
		}(i)
	}
	wg.Wait()
	for i, err := range errs {
		if err != nil {
			t.Fatalf("concurrent measure %d: %v", i, err)
		}
	}
	// The main instance must be untouched by measurements.
	if status := xrayStatus(); status == "" || status[0] == ' ' {
		t.Fatalf("unexpected main status %q", status)
	}
}
