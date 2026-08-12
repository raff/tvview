#!/bin/sh
# Installs a NOPASSWD sudoers.d rule scoped to this exact vpnhelper binary,
# so raiseKernelInterface (vpn_kernel_darwin.go) can elevate it via
# `sudo -n` without a macOS admin-password prompt on every VPN region
# switch. Only this one binary, invoked at this one absolute path, is
# exempted — nothing else on the machine gains passwordless sudo, and
# nobody but the account named below can use this rule.
#
# Run once, with sudo, from the account that runs TVView.app:
#   sudo scripts/install-vpn-helper.sh [/path/to/TVView.app]
#
# The rule is pinned to an absolute path, not a name, so re-run this
# whenever the app is (re)installed somewhere other than /Applications, or
# vpnhelper stops being passwordless (e.g. after moving the app). It is
# *not* affected by rebuilding in place: `make install` overwrites the
# binary at the same path, which the rule doesn't care about.
#
# To undo: scripts/uninstall-vpn-helper.sh, or
#   sudo rm /etc/sudoers.d/tvview-vpnhelper

set -eu

if [ "$(id -u)" -ne 0 ]; then
	echo "run this with sudo: sudo $0 $*" >&2
	exit 1
fi

APP="${1:-/Applications/TVView.app}"
HELPER="$APP/Contents/MacOS/vpnhelper"

if [ ! -x "$HELPER" ]; then
	echo "no vpnhelper executable at $HELPER" >&2
	exit 1
fi

# $SUDO_USER is who actually ran `sudo` — the rule is scoped to them, not to
# root (the account this script itself is running as).
TARGET_USER="${SUDO_USER:-}"
if [ -z "$TARGET_USER" ]; then
	echo "run this via sudo from your normal user account (SUDO_USER is unset)" >&2
	exit 1
fi

RULE_FILE=/etc/sudoers.d/tvview-vpnhelper
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

printf '%s ALL=(root) NOPASSWD: %s\n' "$TARGET_USER" "$HELPER" >"$TMP"

if ! visudo -cf "$TMP" >/dev/null; then
	echo "generated sudoers rule failed validation, not installing" >&2
	exit 1
fi

install -m 0440 -o root -g wheel "$TMP" "$RULE_FILE"
echo "installed $RULE_FILE:"
cat "$RULE_FILE"
