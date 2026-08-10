package main

import "testing"

// The built-in channels.yaml (embedded via go:embed, used whenever no user
// config exists) has a real vpn block to demonstrate the feature. It must
// stay parseable under whatever the current VPNConfig schema is — a schema
// change that forgets to update it breaks every first run.
func TestDefaultConfigParses(t *testing.T) {
	cfg, err := parseConfig(defaultConfig, "")
	if err != nil {
		t.Fatalf("built-in channels.yaml: %v", err)
	}
	if cfg.VPN == nil || len(cfg.VPN.Tunnels) == 0 {
		t.Fatalf("built-in channels.yaml: expected a vpn.tunnels block, got %+v", cfg.VPN)
	}
}
