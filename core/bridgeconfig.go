package main

import (
	"encoding/json"
	"fmt"
)

// Bridge mode (0.64): the eBPF data plane is replaced by
// bpf2socks (Asterisk4Magisk, GPL-3.0, vendored under
// bridge/bpf2socks) - the same bridge AsteriskNG ships.
// Its cgroup programs rewrite app connections to token
// addresses at connect/sendmsg time and its userspace
// relay forwards them to a SOCKS5 server with the original
// destination preserved; DNS transactions are tracked and
// hijacked inside the bridge. No netfilter steering, so
// there are no rules for the system to quietly drop (the
// 0.59-0.63 failure class), and no netd-cache gap: queries
// are intercepted at the socket layer before netd's cache
// answers can pin a domain to a polluted address.
//
// The sing-box side is the 0.62 daemon config with the
// redirect/tproxy inbounds swapped for one SOCKS inbound
// the bridge dials. flboxd supervises the bridge process
// (see cmd/flboxd): it probes first, then runs it with
// --pid /dev/null, and both share one group id so the
// bridge's built-in self-GID bypass also covers the box's
// own egress - the loop prevention asteriskd relies on.
const (
	bridgeSocksPort  = 7891
	bridgeListenPort = 65534
	bridgePinnedDir  = "/sys/fs/bpf/flbox/bpf2socks"
)

// bridgeCoreConfig returns the sing-box config for bridge
// mode: the ebpf daemon config with a SOCKS inbound.
func bridgeCoreConfig(clashYAML, selectedNode string) (string, error) {
	raw, err := ebpfConfig(clashYAML, selectedNode)
	if err != nil {
		return "", err
	}
	var root map[string]any
	if err := json.Unmarshal([]byte(raw), &root); err != nil {
		return "", err
	}
	root["inbounds"] = []any{
		map[string]any{
			"type":        "socks",
			"tag":         "socks-in",
			"listen":      "127.0.0.1",
			"listen_port": bridgeSocksPort,
		},
	}
	out, err := json.Marshal(root)
	if err != nil {
		return "", err
	}
	return string(out), nil
}

// bridgeFileConfig returns the bpf2socks JSON config.
// mode follows the bridge policy contract: 2 global,
// 0 blacklist (uids bypass), 1 whitelist (only uids are
// proxied). uids are Android app uids resolved by the app
// from the per-app package preferences.
func bridgeFileConfig(ipv6 bool, mode int, uids []int) (string, error) {
	if mode < 0 || mode > 2 {
		return "", fmt.Errorf("bridge policy mode %d out of range", mode)
	}
	uidList := make([]any, 0, len(uids))
	for _, u := range uids {
		if u < 0 {
			return "", fmt.Errorf("bridge uid %d out of range", u)
		}
		uidList = append(uidList, u)
	}
	cfg := map[string]any{
		"version":             1,
		"socksHost":           "127.0.0.1",
		"socksPort":           bridgeSocksPort,
		"bridgeListenAddress": "127.0.0.1",
		"bridgePort":          bridgeListenPort,
		"pinnedObjectDir":     bridgePinnedDir,
		"cgroupPath":          "/sys/fs/cgroup",
		"enableIpv6":          ipv6,
		"enableDnsHijack":     true,
		// LAN destinations never enter the bridge; the
		// box's ip_is_private rule stays as backstop for
		// anything that still arrives.
		"bypassPrivateCidrsV4": []any{
			"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
			"169.254.0.0/16", "100.64.0.0/10",
		},
		"policy": map[string]any{
			"mode": mode,
			"uids": uidList,
		},
	}
	out, err := json.Marshal(cfg)
	if err != nil {
		return "", err
	}
	return string(out), nil
}

// bridgeConfigs returns the JSON envelope the app writes
// to disk: {"core": "<sing-box config>", "bridge":
// "<bpf2socks config>"}.
func bridgeConfigs(clashYAML, selectedNode string, ipv6 bool, mode int, uids []int) (string, error) {
	core, err := bridgeCoreConfig(clashYAML, selectedNode)
	if err != nil {
		return "", err
	}
	bridge, err := bridgeFileConfig(ipv6, mode, uids)
	if err != nil {
		return "", err
	}
	envelope, err := json.Marshal(map[string]string{
		"core":   core,
		"bridge": bridge,
	})
	if err != nil {
		return "", err
	}
	return string(envelope), nil
}
