//go:build !darwin || ios

package main

// start brings the tunnel up in-process: iOS has no vpnhelper and no way to
// elevate. (The iOS app gets a system VPN through a Network Extension instead
// where a real TCP stack matters.)
func start(confPath string) (closer, int, error) { return userspace(confPath) }
