//go:build darwin && !ios

package main

import (
	"os"

	"tvview/internal/kernelvpn"
)

// start brings the tunnel up on a real kernel utun interface raised by vpnhelper,
// as the Go app does: the CDNs that drop a userspace TCP stack (BBC iPlayer's)
// accept it, and only the web view's sockets are bound to the interface, so a
// VPN already up for something else is left alone. The first start per region
// shows macOS's administrator password dialog. vpnhelper must sit next to the
// app's own executable (Contents/MacOS).
func start(confPath string) (closer, int, error) {
	if os.Getenv("TVVPN_USERSPACE") != "" {
		return userspace(confPath)
	}
	t, err := kernelvpn.Start(confPath)
	if err != nil {
		return nil, 0, err
	}
	return t, t.Port, nil
}
