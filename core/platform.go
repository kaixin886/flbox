package main

import (
	"errors"

	"github.com/sagernet/sing-box/experimental/libbox"
)

// corePlatform is the Go-side PlatformInterface for libbox. In sing-box's
// own Android client this interface is implemented in Kotlin; FlBox keeps
// the core self-contained, so platform services that only a real Android
// runtime can provide are stubbed here. Milestone 1 is proxy-only: TUN
// stays closed and OpenTun reports that directly.
//
// TODO(M1): the default-interface monitor never calls back, so interface
// changes are invisible to the core; verify outbound behaviour on device
// and revisit if dials pick a stale default interface.
type corePlatform struct{}

var _ libbox.PlatformInterface = corePlatform{}

func (corePlatform) LocalDNSTransport() libbox.LocalDNSTransport { return nil }

func (corePlatform) UsePlatformAutoDetectInterfaceControl() bool { return false }

func (corePlatform) AutoDetectInterfaceControl(fd int32) error { return nil }

func (corePlatform) OpenTun(options libbox.TunOptions) (int32, error) {
	return 0, errors.New("tun is not available until milestone M2")
}

func (corePlatform) FindConnectionOwner(
	ipProtocol int32,
	sourceAddress string,
	sourcePort int32,
	destinationAddress string,
	destinationPort int32,
) (*libbox.ConnectionOwner, error) {
	// Only process-name rules need this; unsupported in proxy-only mode.
	return nil, errors.New("connection owner lookup is not supported")
}

func (corePlatform) StartDefaultInterfaceMonitor(listener libbox.InterfaceUpdateListener) error {
	return nil
}

func (corePlatform) CloseDefaultInterfaceMonitor(listener libbox.InterfaceUpdateListener) error {
	return nil
}

type emptyInterfaces struct{}

func (emptyInterfaces) Next() *libbox.NetworkInterface { return nil }
func (emptyInterfaces) HasNext() bool                   { return false }

func (corePlatform) GetInterfaces() (libbox.NetworkInterfaceIterator, error) {
	return emptyInterfaces{}, nil
}

func (corePlatform) UnderNetworkExtension() bool { return false }

func (corePlatform) IncludeAllNetworks() bool { return false }

func (corePlatform) ReadWIFIState() *libbox.WIFIState { return nil }

func (corePlatform) ClearDNSCache() {}

func (corePlatform) SendNotification(notification *libbox.Notification) error { return nil }

func (corePlatform) CancelNotification(identifier string, typeID int32) error { return nil }

func (corePlatform) StartNeighborMonitor(listener libbox.NeighborUpdateListener) error {
	return nil
}

func (corePlatform) CloseNeighborMonitor(listener libbox.NeighborUpdateListener) error {
	return nil
}

func (corePlatform) RegisterMyInterface(name string) {}

func (corePlatform) UsePlatformShell() bool { return false }

func (corePlatform) CheckPlatformShell() error { return nil }

func (corePlatform) OpenShellSession(
	user *libbox.PlatformUser,
	command string,
	environ libbox.StringIterator,
	term string,
	rows int32,
	cols int32,
) (libbox.ShellSession, error) {
	return nil, errors.New("platform shell is not supported")
}

func (corePlatform) LookupUser(username string) (*libbox.PlatformUser, error) {
	return nil, errors.New("user lookup is not supported")
}

func (corePlatform) LookupSFTPServer() (string, error) {
	return "", errors.New("sftp server lookup is not supported")
}

func (corePlatform) ReadSystemSSHHostKey() (string, error) {
	return "", errors.New("ssh host key read is not supported")
}

func (corePlatform) TailscaleHostname() string { return "" }

func (corePlatform) UsePlatformBridge() bool { return false }

func (corePlatform) CreateBridge(options *libbox.BridgeOptions) (libbox.BridgeSession, error) {
	return nil, errors.New("platform bridge is not supported")
}
