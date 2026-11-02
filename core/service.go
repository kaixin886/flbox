package main

import (
	"errors"
	"sync"

	"github.com/sagernet/sing-box/experimental/libbox"
)

// Service lifecycle follows the libbox route used by sing-box's own
// clients: Setup once per process, then a CommandServer that owns the
// running instance. Milestone 1 runs proxy-only (no TUN inbound), so the
// CommandServer is used purely as the start/stop/reload handle.
var (
	svcMu     sync.Mutex
	svcServer *libbox.CommandServer
	svcSetup  bool
)

func setupCore(basePath, workingPath, tempPath string) error {
	svcMu.Lock()
	defer svcMu.Unlock()
	if svcSetup {
		return nil
	}
	err := libbox.Setup(&libbox.SetupOptions{
		BasePath:    basePath,
		WorkingPath: workingPath,
		TempPath:    tempPath,
		LogMaxLines: 3000,
	})
	if err != nil {
		return err
	}
	svcSetup = true
	return nil
}

func startCore(configJSON string) error {
	svcMu.Lock()
	defer svcMu.Unlock()
	if !svcSetup {
		return errors.New("FlboxSetup must be called before FlboxStart")
	}
	if svcServer == nil {
		created, err := libbox.NewCommandServer(coreHandler{}, corePlatform{})
		if err != nil {
			return err
		}
		if err := created.Start(); err != nil {
			return err
		}
		svcServer = created
	}
	return svcServer.StartOrReloadService(configJSON, &libbox.OverrideOptions{})
}

func stopCore() error {
	svcMu.Lock()
	defer svcMu.Unlock()
	if svcServer == nil {
		return nil
	}
	err := svcServer.CloseService()
	svcServer.Close()
	svcServer = nil
	return err
}
