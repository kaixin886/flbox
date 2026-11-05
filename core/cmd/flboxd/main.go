// flboxd is FlBox's root daemon: a standalone process
// the app launches through su for the root modes.
// The app process itself can never hold root, so everything
// that needs it (creating a TUN device and installing routes
// for TUN mode; running the core beside the bpf2socks bridge
// for eBPF mode) lives here. The core flavor follows the
// config file: sing-box JSON for TUN mode, Xray JSON for
// bridge mode (0.66, AsteriskNG's bridge-plus-Xray pairing).
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

	"github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/include"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/common/json"
	xcore "github.com/xtls/xray-core/core"
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

// runBox starts the sing-box instance and blocks until
// SIGTERM/SIGINT. readyPath/readyText, when set, are
// written right after a successful start: the plain path
// uses it as its status file ("running"), the supervised
// core as a pure readiness beacon for the supervisor.
func runBox(configPath, readyPath, readyText string) error {
	raw, err := os.ReadFile(configPath)
	if err != nil {
		return err
	}
	ctx := include.Context(context.Background())
	options, err := json.UnmarshalExtendedContext[option.Options](ctx, raw)
	if err != nil {
		return fmt.Errorf("parse config: %w", err)
	}
	instance, err := box.New(box.Options{Context: ctx, Options: options})
	if err != nil {
		return fmt.Errorf("create box: %w", err)
	}
	if err := instance.Start(); err != nil {
		return fmt.Errorf("start box: %w", err)
	}
	if readyPath != "" {
		writeStatus(readyPath, readyText)
	}
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
	<-sig
	_ = instance.Close()
	return nil
}

// configIsXray tells the two core config flavors apart:
// Xray inbounds carry a "protocol", sing-box inbounds a
// "type". The app generates exactly one flavor per mode,
// so the first inbound settles it.
func configIsXray(raw []byte) bool {
	var probe struct {
		Inbounds []struct {
			Protocol string `json:"protocol"`
		} `json:"inbounds"`
	}
	if err := stdjson.Unmarshal(raw, &probe); err != nil {
		return false
	}
	return len(probe.Inbounds) > 0 && probe.Inbounds[0].Protocol != ""
}

// runXray is runBox's Xray twin: start the instance,
// signal readiness, block until SIGTERM/SIGINT.
func runXray(configPath, readyPath, readyText string) error {
	raw, err := os.ReadFile(configPath)
	if err != nil {
		return err
	}
	inst, err := xcore.StartInstance("json", raw)
	if err != nil {
		return fmt.Errorf("start xray: %w", err)
	}
	if readyPath != "" {
		writeStatus(readyPath, readyText)
	}
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
	<-sig
	_ = inst.Close()
	return nil
}

// runCore dispatches on the config flavor.
func runCore(configPath, readyPath, readyText string) error {
	raw, err := os.ReadFile(configPath)
	if err != nil {
		return err
	}
	if configIsXray(raw) {
		return runXray(configPath, readyPath, readyText)
	}
	return runBox(configPath, readyPath, readyText)
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
		if err := runCore(args[1], args[2], "ready\n"); err != nil {
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
