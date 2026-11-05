// flboxd is FlBox's root daemon: a standalone process
// the app launches through su for the root mode.
// The app process itself can never hold root, so everything
// that needs it (running the Xray core beside the
// bpf2socks bridge) lives here. The core is Xray since
// 0.66 (AsteriskNG's bridge-plus-Xray pairing); 0.68
// removed the sing-box TUN flavor together with Root TUN
// mode, so every config this daemon receives is Xray JSON.
//
// Usage:
//
//	flboxd <config.json> <status-file>
//	flboxd <config.json> <status-file> <bridge-config.json>
//	flboxd --core <config.json> <ready-file>
//
// The status file is the whole control channel back to the
// app: the daemon writes "running\n<pid>\n" once everything
// is up, "error: <message>" when it cannot start, and
// "stopped\n" after a clean shutdown on SIGTERM/SIGINT. The
// app stops the daemon by signalling the pid from that file.
//
// Bridge mode (0.64) is a supervisor: the bpf2socks bridge
// bypasses its own effective GID, so the core and the bridge
// are both spawned with one shared group id - the bridge
// then never recaptures the core's egress, while netd (a
// different group) is hooked like any app. Both children
// carry a parent-death signal, so even a SIGKILL of the
// supervisor lets them shut down cleanly (the bridge
// restores the original cgroup programs on exit).
package main

import (
	"context"
	stdjson "encoding/json"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/xtls/xray-core/common/platform"
	xcore "github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/features/stats"
	_ "github.com/xtls/xray-core/main/distro/all"
)

// bridgeGID is the shared group id of the core and bridge
// children in bridge mode. Deliberately obscure: any other
// process running with this group would also bypass the
// bridge, so it must not collide with a system group.
const bridgeGID = 55991

func writeStatus(path, text string) {
	_ = os.WriteFile(path, []byte(text), 0644)
}

// runXray starts the Xray instance, signals readiness,
// and blocks until SIGTERM/SIGINT. When trafficPath is
// non-empty (the supervised core child), a goroutine
// publishes the cumulative proxy counters there every
// two seconds: the core lives in this process, so the
// app can only learn its traffic from that file.
func runXray(configPath, readyPath, readyText, trafficPath string) error {
	raw, err := os.ReadFile(configPath)
	if err != nil {
		return err
	}
	// Rule mode loads geoip.dat / geosite.dat from the
	// asset location; the config lives in the app's
	// documents directory, which is where the app
	// releases them.
	os.Setenv(platform.AssetLocation, filepath.Dir(configPath))
	inst, err := xcore.StartInstance("json", raw)
	if err != nil {
		return fmt.Errorf("start xray: %w", err)
	}
	if readyPath != "" {
		writeStatus(readyPath, readyText)
	}
	if trafficPath != "" {
		go publishTraffic(inst, trafficPath)
	}
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
	<-sig
	_ = inst.Close()
	return nil
}

// publishTraffic writes {"up":N,"down":N} (cumulative
// proxy-outbound bytes) to path every two seconds,
// atomically, for the app's dashboard polling.
func publishTraffic(inst *xcore.Instance, path string) {
	feature := inst.GetFeature(stats.ManagerType())
	mgr, ok := feature.(stats.Manager)
	if !ok || mgr == nil {
		return
	}
	counter := func(name string) int64 {
		c := mgr.GetCounter(name)
		if c == nil {
			return 0
		}
		return c.Value()
	}
	for {
		raw, err := stdjson.Marshal(map[string]any{
			"up":   counter("outbound>>>proxy>>>traffic>>>uplink"),
			"down": counter("outbound>>>proxy>>>traffic>>>downlink"),
		})
		if err == nil {
			tmp := path + ".tmp"
			if os.WriteFile(tmp, raw, 0644) == nil {
				_ = os.Rename(tmp, path)
			}
		}
		time.Sleep(2 * time.Second)
	}
}

// runCore runs the daemon's only core flavor: Xray.
func runCore(configPath, readyPath, readyText string) error {
	return runXray(configPath, readyPath, readyText, "")
}

func bridgeBinaryPath() (string, error) {
	self, err := os.Executable()
	if err != nil {
		return "", err
	}
	p := filepath.Join(filepath.Dir(self), "bpf2socks")
	if _, err := os.Stat(p); err != nil {
		return "", fmt.Errorf("bridge binary missing next to flboxd: %w", err)
	}
	return p, nil
}

func childCmd(name string, args ...string) *exec.Cmd {
	cmd := exec.Command(name, args...)
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Credential: &syscall.Credential{Uid: 0, Gid: bridgeGID},
		Pdeathsig:  syscall.SIGTERM,
	}
	return cmd
}

// The IPv6 guard held during bridge sessions. The
// bridge only declines to capture IPv6 (its emitted
// programs bypass it), so "disabled" has to mean the
// system itself has no IPv6 to leak: the supervisor
// writes disable_ipv6=1 on every interface - the
// mechanism AsteriskNG's asteriskd uses (sysctl, not
// packet filtering) - re-asserts it every few seconds
// because netd re-enables IPv6 when networks change,
// and restores the recorded values when the session
// ends. The ip6tables drop chain this replaces
// (0.68.1) installed and verified cleanly yet did not
// stop the leak on the reference device, so it is gone
// rather than kept as a second guess.
type v6Guard struct {
	saved    map[string]string
	done     chan struct{}
	restored bool
}

func v6ReadDisable(name string) (string, error) {
	b, err := os.ReadFile("/proc/sys/net/ipv6/conf/" + name + "/disable_ipv6")
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(b)), nil
}

func v6WriteDisable(name, value string) error {
	return os.WriteFile("/proc/sys/net/ipv6/conf/"+name+"/disable_ipv6", []byte(value), 0o644)
}

// v6HasGlobalAddress reports whether any global-scope
// IPv6 address exists (a leak needs one): the kernel's
// if_inet6 table lists every address as 32 hex digits;
// link-local fe80::/10 and loopback ::1 do not count.
func v6HasGlobalAddress() bool {
	b, err := os.ReadFile("/proc/net/if_inet6")
	if err != nil {
		return false
	}
	for _, line := range strings.Split(string(b), "\n") {
		fields := strings.Fields(line)
		if len(fields) == 0 || len(fields[0]) != 32 {
			continue
		}
		addr := strings.ToLower(fields[0])
		if strings.HasPrefix(addr, "fe8") || strings.HasPrefix(addr, "fe9") ||
			strings.HasPrefix(addr, "fea") || strings.HasPrefix(addr, "feb") {
			continue
		}
		if addr == "00000000000000000000000000000001" {
			continue
		}
		return true
	}
	return false
}

// bridgeWantsIpv6 reports whether the bridge config
// the supervisor is about to hand over enables IPv6
// capture. An unreadable config means false: the
// guard is the safe default.
// bridgeDisablesIpv6 reads the disableSystemIpv6 key
// the app stamps into the bridge file - AS's separate
// RootIpv6Disabler switch riding the same file (the
// bridge only looks keys up, so it never sees it).
// Absent means on: configs published before the key
// existed were written when off always meant disabled.
func bridgeDisablesIpv6(path string) bool {
	if path == "" {
		return true
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return true
	}
	var cfg struct {
		DisableSystemIpv6 *bool `json:"disableSystemIpv6"`
	}
	if err := stdjson.Unmarshal(raw, &cfg); err != nil || cfg.DisableSystemIpv6 == nil {
		return true
	}
	return *cfg.DisableSystemIpv6
}

func bridgeWantsIpv6(path string) bool {
	data, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	var cfg struct {
		EnableIpv6 bool `json:"enableIpv6"`
	}
	return stdjson.Unmarshal(data, &cfg) == nil && cfg.EnableIpv6
}

func v6GuardStart() (*v6Guard, error) {
	g := &v6Guard{saved: map[string]string{}, done: make(chan struct{})}
	entries, err := os.ReadDir("/proc/sys/net/ipv6/conf")
	if err != nil {
		if os.IsNotExist(err) {
			// No IPv6 stack at all: nothing can leak.
			return g, nil
		}
		return nil, fmt.Errorf("ipv6 guard: %w", err)
	}
	var failed []string
	for _, e := range entries {
		name := e.Name()
		// "all" fans a write out to every interface,
		// which would corrupt the restore bookkeeping;
		// "default" is kept (it covers interfaces that
		// appear later), loopback is never touched.
		if name == "lo" || name == "all" {
			continue
		}
		cur, err := v6ReadDisable(name)
		if err != nil {
			continue
		}
		g.saved[name] = cur
		if cur == "1" {
			continue
		}
		if err := v6WriteDisable(name, "1"); err != nil {
			failed = append(failed, name)
			fmt.Fprintf(os.Stderr, "flboxd: ipv6 guard: disable %s: %v\n", name, err)
			continue
		}
		fmt.Fprintf(os.Stderr, "flboxd: ipv6 guard: %s disable_ipv6 %s -> 1\n", name, cur)
	}
	if len(failed) > 0 && v6HasGlobalAddress() {
		g.restore()
		return nil, fmt.Errorf("ipv6 guard: could not disable IPv6 on %s while global addresses exist", strings.Join(failed, ", "))
	}
	go g.watch()
	return g, nil
}

func (g *v6Guard) watch() {
	t := time.NewTicker(3 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-g.done:
			return
		case <-t.C:
			for name := range g.saved {
				cur, err := v6ReadDisable(name)
				if err == nil && cur != "1" {
					if err := v6WriteDisable(name, "1"); err == nil {
						fmt.Fprintf(os.Stderr, "flboxd: ipv6 guard: re-asserted disable on %s (was %s)\n", name, cur)
					}
				}
			}
		}
	}
}

func (g *v6Guard) restore() {
	if g.restored {
		return
	}
	g.restored = true
	close(g.done)
	for name, orig := range g.saved {
		if err := v6WriteDisable(name, orig); err != nil {
			fmt.Fprintf(os.Stderr, "flboxd: ipv6 guard: restore %s=%s: %v\n", name, orig, err)
		}
	}
	fmt.Fprintf(os.Stderr, "flboxd: ipv6 guard: restored\n")
}

func runSupervisor(configPath, statusPath, bridgeConfigPath string) error {
	bridgeBin, err := bridgeBinaryPath()
	if err != nil {
		return err
	}
	if err := os.MkdirAll("/sys/fs/bpf/flbox", 0o755); err != nil {
		return fmt.Errorf("prepare bpf fs dir: %w", err)
	}
	// Capability probe first: a kernel that cannot run the
	// bridge fails here with the probe's JSON in the log,
	// before anything is hooked.
	probeCtx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	probeOut, err := exec.CommandContext(probeCtx, bridgeBin, "--probe", "--config", bridgeConfigPath).CombinedOutput()
	cancel()
	fmt.Fprintf(os.Stderr, "flboxd: bridge probe: %s\n", strings.TrimSpace(string(probeOut)))
	if err != nil {
		return fmt.Errorf("bridge probe failed: %w", err)
	}
	// IPv6 in bridge mode follows the user's switch,
	// carried by the bridge config's enableIpv6 (the
	// app writes it from the settings toggle). Switch
	// on: the bridge tries to capture v6 itself and the
	// guard stands down. Switch off: the bridge only
	// declines to capture, which by itself would leave
	// the system route - and the leak - in place, so
	// the supervisor's sysctl guard is what makes
	// disabled true; failing it fails the start rather
	// than leaking quietly.
	var guard *v6Guard
	if bridgeWantsIpv6(bridgeConfigPath) {
		fmt.Fprintln(os.Stderr, "flboxd: ipv6 guard: off - user switch on, the bridge captures IPv6")
		guard = &v6Guard{saved: map[string]string{}, done: make(chan struct{})}
	} else if !bridgeDisablesIpv6(bridgeConfigPath) {
		fmt.Fprintln(os.Stderr, "flboxd: ipv6 guard: off - disabler switch off, IPv6 stays native")
		guard = &v6Guard{saved: map[string]string{}, done: make(chan struct{})}
	} else {
		var err error
		guard, err = v6GuardStart()
		if err != nil {
			return err
		}
	}
	defer guard.restore()
	self, err := os.Executable()
	if err != nil {
		return err
	}
	readyPath := configPath + ".ready"
	_ = os.Remove(readyPath)
	core := childCmd(self, "--core", configPath, readyPath)
	if err := core.Start(); err != nil {
		return fmt.Errorf("start core: %w", err)
	}
	coreDone := make(chan error, 1)
	go func() { coreDone <- core.Wait() }()
	// The bridge dials the core's SOCKS inbound, so it may
	// only start once the core reports ready.
	deadline := time.Now().Add(15 * time.Second)
	for {
		if _, err := os.Stat(readyPath); err == nil {
			break
		}
		select {
		case err := <-coreDone:
			return fmt.Errorf("core exited before ready: %v", err)
		default:
		}
		if time.Now().After(deadline) {
			_ = core.Process.Kill()
			return fmt.Errorf("core did not become ready in 15s")
		}
		time.Sleep(100 * time.Millisecond)
	}
	// --dns-enhancement is how AS gets system-resolver
	// queries captured: netd marks its DNS sockets, and
	// only with this flag does the bridge force-proxy
	// marked port-53 traffic. Without it those queries
	// egressed via the carrier resolver (the DNS leak
	// tests showed the carrier in every mode).
	bridge := childCmd(bridgeBin, "--start", "--config", bridgeConfigPath, "--pid", "/dev/null", "--dns-enhancement")
	if err := bridge.Start(); err != nil {
		_ = core.Process.Signal(syscall.SIGTERM)
		<-coreDone
		return fmt.Errorf("start bridge: %w", err)
	}
	bridgeDone := make(chan error, 1)
	go func() { bridgeDone <- bridge.Wait() }()
	writeStatus(statusPath, fmt.Sprintf("running\n%d\n", os.Getpid()))
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
	var runErr error
	select {
	case <-sig:
	case err := <-coreDone:
		runErr = fmt.Errorf("core exited: %v", err)
	case err := <-bridgeDone:
		runErr = fmt.Errorf("bridge exited: %v", err)
	}
	_ = bridge.Process.Signal(syscall.SIGTERM)
	_ = core.Process.Signal(syscall.SIGTERM)
	select {
	case <-bridgeDone:
	case <-time.After(10 * time.Second):
		_ = bridge.Process.Kill()
	}
	select {
	case <-coreDone:
	case <-time.After(10 * time.Second):
		_ = core.Process.Kill()
	}
	return runErr
}

func main() {
	fail := func(statusPath string, err error) {
		writeStatus(statusPath, "error: "+err.Error()+"\n")
		fmt.Fprintln(os.Stderr, "flboxd:", err)
		os.Exit(1)
	}
	args := os.Args[1:]
	switch {
	case len(args) == 3 && args[0] == "--core":
		// The supervised core also publishes its traffic
		// counters next to the config for the app to poll.
		trafficPath := filepath.Join(filepath.Dir(args[1]), "root-traffic.json")
		if err := runXray(args[1], args[2], "ready\n", trafficPath); err != nil {
			fmt.Fprintln(os.Stderr, "flboxd core:", err)
			os.Exit(1)
		}
	case len(args) == 2:
		running := fmt.Sprintf("running\n%d\n", os.Getpid())
		if err := runCore(args[0], args[1], running); err != nil {
			fail(args[1], err)
		}
		writeStatus(args[1], "stopped\n")
	case len(args) == 3:
		if err := runSupervisor(args[0], args[1], args[2]); err != nil {
			fail(args[1], err)
		}
		writeStatus(args[1], "stopped\n")
	default:
		fmt.Fprintln(os.Stderr, "usage: flboxd <config.json> <status-file> [bridge-config.json]")
		os.Exit(2)
	}
}
