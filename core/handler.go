package main

import (
	"errors"

	"github.com/sagernet/sing-box/experimental/libbox"
)

// coreHandler receives lifecycle callbacks from the libbox command
// server. Milestone 1 drives start/stop from Dart through the FFI entry
// points, so most callbacks are intentional no-ops for now.
//
// TODO(M1): forward ServiceStop/ServiceReload to Dart so the UI can
// reflect core-initiated state changes instead of only its own actions.
type coreHandler struct{}

var _ libbox.CommandServerHandler = coreHandler{}

func (coreHandler) ServiceStop() error { return nil }

func (coreHandler) ServiceReload() error { return nil }

func (coreHandler) GetSystemProxyStatus() (*libbox.SystemProxyStatus, error) {
	// The core never manages the system proxy; apps point at the local
	// mixed inbound explicitly.
	return &libbox.SystemProxyStatus{Available: false, Enabled: false}, nil
}

func (coreHandler) SetSystemProxyEnabled(enabled bool) error { return nil }

func (coreHandler) TriggerNativeCrash() error { return nil }

func (coreHandler) WriteDebugMessage(message string) {}

func (coreHandler) ConnectSSHAgent() (int32, error) {
	return 0, errors.New("ssh agent is not supported")
}
