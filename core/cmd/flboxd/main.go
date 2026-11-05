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
//   flboxd <config.json> <status-file>
//   flboxd <config.json> <status-file> <bridge-config.json>
//   flboxd --core <config.json> <ready-file>
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
	bridge := childCmd(bridgeBin, "--start", "--config", bridgeConfigPath, "--pid", "/dev/null")
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
