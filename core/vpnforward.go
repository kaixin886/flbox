package main

import (
	"errors"
	"sync/atomic"
)

// The VPN data path. A sing-box instance whose only job is to own
// the TUN side and forward every flow into the Xray core's mixed
// inbound on 127.0.0.1:7890 - the classic tun2socks shape, with
// sing-box's stack doing the packet work (the same stack the user's
// other clients use without trouble).
//
// Why not Xray's own tun inbound: on the user's phone its gVisor
// stack intermittently killed some apps' connections right after
// the tunnel came up (Telegram stuck on "connecting", error chains
// ending in gVisor errors like "endpoint is closed for send"),
// while the very same core and node carried those destinations
// fine over the SOCKS inbound. The fd comes from the Android
// VpnService via Dart; the platform's OpenTun hands sing-box a
// duplicate of it (see platform.go).

var vpnTunFd atomic.Int32

const vpnForwardConfig = `{
  "log": {"level": "warn", "timestamp": false},
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "address": ["172.19.0.1/30"],
      "mtu": 1500,
      "auto_route": false,
      "strict_route": false,
      "stack": "gvisor"
    }
  ],
  "outbounds": [
    {
      "type": "socks",
      "tag": "out",
      "server": "127.0.0.1",
      "server_port": 7890,
      "version": "5"
    }
  ],
  "route": {"final": "out"}
}`

func startVpnForward(fd int) error {
	if fd <= 0 {
		return errors.New("invalid tun fd")
	}
	vpnTunFd.Store(int32(fd))
	if err := startCore(vpnForwardConfig); err != nil {
		vpnTunFd.Store(0)
		return err
	}
	return nil
}

func stopVpnForward() error {
	err := stopCore()
	vpnTunFd.Store(0)
	return err
}

func vpnForwardActive() bool {
	svcMu.Lock()
	defer svcMu.Unlock()
	return svcServer != nil
}
