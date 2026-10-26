package main

import "tvview/swift/vpn/tunnel"

// closer is what both backends return: something that stops a running tunnel.
type closer interface{ Close() }

// userspace is the in-process tunnel (no privileges, no interface): used on iOS
// and the simulator, and on macOS only when TVVPN_USERSPACE is set, to compare.
func userspace(confPath string) (closer, int, error) {
	t, err := tunnel.Start(confPath)
	if err != nil {
		return nil, 0, err
	}
	return t, t.Port, nil
}
