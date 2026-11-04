// flboxd is FlBox's root daemon: a standalone sing-box
// process the app launches through su for the root modes.
// The app process itself can never hold root, so everything
// that needs it (creating a TUN device and installing routes
// for TUN mode; loading BPF programs for eBPF mode later)
// lives here.
//
// Usage: flboxd <config.json> <status-file>
//
// The status file is the whole control channel back to the
// app: the daemon writes "running\n<pid>\n" once the box is
// up, "error: <message>" when it cannot start, and
// "stopped\n" after a clean shutdown on SIGTERM/SIGINT. The
// app stops the daemon by signalling the pid from that file.
package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/include"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/common/json"
)

func writeStatus(path, text string) {
	_ = os.WriteFile(path, []byte(text), 0644)
}

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: flboxd <config.json> <status-file>")
		os.Exit(2)
	}
	configPath, statusPath := os.Args[1], os.Args[2]
	fail := func(err error) {
		writeStatus(statusPath, "error: "+err.Error()+"\n")
		fmt.Fprintln(os.Stderr, "flboxd:", err)
		os.Exit(1)
	}
	raw, err := os.ReadFile(configPath)
	if err != nil {
		fail(err)
	}
	ctx := include.Context(context.Background())
	options, err := json.UnmarshalExtendedContext[option.Options](ctx, raw)
	if err != nil {
		fail(fmt.Errorf("parse config: %w", err))
	}
	instance, err := box.New(box.Options{Context: ctx, Options: options})
	if err != nil {
		fail(fmt.Errorf("create box: %w", err))
	}
	if err := instance.Start(); err != nil {
		fail(fmt.Errorf("start box: %w", err))
	}
	writeStatus(statusPath, fmt.Sprintf("running\n%d\n", os.Getpid()))
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
	<-sig
	_ = instance.Close()
	writeStatus(statusPath, "stopped\n")
}
