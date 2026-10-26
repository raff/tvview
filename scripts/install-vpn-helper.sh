#!/bin/sh
# Installs a NOPASSWD sudoers.d rule scoped to each installed copy of vpnhelper, so
# raiseKernelInterface (internal/kernelvpn) can elevate it via `sudo -n` without a
# macOS admin-password prompt on every VPN region start. Only those exact binaries,
# invoked at those exact absolute paths, are exempted — nothing else on the machine
# gains passwordless sudo, and nobody but the account named below can use the rule.
#
# Run once, with sudo, from the account that runs the app:
#   sudo scripts/install-vpn-helper.sh [/path/to/App.app ...]
#
# With no arguments it covers every app of ours found in /Applications (the Go app,
# TVView.app, and the Swift app, "TV View.app"), so installing one never drops the
# rule for the other. With arguments it covers exactly those apps.
#
# Each rule is pinned to an absolute path, not a name, so re-run this when an app is
# installed somewhere other than /Applications, or after moving it. It is *not*
# affected by rebuilding in place: `make install` overwrites the binary at the same
# path, which the rule doesn't care about.
#
# Know what this trades: the rule trusts whatever file is at that path, and an app
# in /Applications is usually owned by you. Anything running as you could replace
# vpnhelper and then run it as root without a password. That is the price of no
# prompt; skip this script, and the dialog comes back, if it is not one you want to pay.
#
#   --check   print the rule that would be installed and validate it, changing nothing
#             (no root needed)
#
# To undo: scripts/uninstall-vpn-helper.sh, or
#   sudo rm /etc/sudoers.d/tvview-vpnhelper

set -eu

CHECK=0
if [ "${1:-}" = "--check" ]; then
	CHECK=1
	shift
fi

if [ "$CHECK" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
	echo "run this with sudo: sudo $0 $*" >&2
	exit 1
fi

# $SUDO_USER is who actually ran `sudo` — the rule is scoped to them, not to
# root (the account this script itself is running as).
if [ "$CHECK" -eq 1 ]; then
	TARGET_USER="${SUDO_USER:-$(id -un)}"
else
	TARGET_USER="${SUDO_USER:-}"
	if [ -z "$TARGET_USER" ]; then
		echo "run this via sudo from your normal user account (SUDO_USER is unset)" >&2
		exit 1
	fi
fi

RULE_FILE=/etc/sudoers.d/tvview-vpnhelper
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

# sudoers separates command names at spaces and treats , : = \ specially, so a path
# like "/Applications/TV View.app/..." has to be backslash-escaped.
escape() {
	printf '%s' "$1" | sed 's/[ ,:=\\]/\\&/g'
}

# add_app APP: appends the rule for APP's vpnhelper to $TMP. Says so, and returns 1,
# when the app has none.
add_app() {
	helper="$1/Contents/MacOS/vpnhelper"
	if [ ! -x "$helper" ]; then
		echo "no vpnhelper executable at $helper" >&2
		return 1
	fi
	printf '%s ALL=(root) NOPASSWD: %s\n' "$TARGET_USER" "$(escape "$helper")" >>"$TMP"
}

found=0
if [ "$#" -gt 0 ]; then
	for app in "$@"; do
		add_app "$app" && found=$((found + 1))
	done
else
	for app in "/Applications/TVView.app" "/Applications/TV View.app"; do
		if [ -x "$app/Contents/MacOS/vpnhelper" ]; then
			add_app "$app" && found=$((found + 1))
		fi
	done
fi

if [ "$found" -eq 0 ]; then
	echo "no vpnhelper found: install an app into /Applications, or pass its path" >&2
	exit 1
fi

if ! visudo -cf "$TMP" >/dev/null; then
	echo "generated sudoers rule failed validation, not installing:" >&2
	cat "$TMP" >&2
	exit 1
fi

if [ "$CHECK" -eq 1 ]; then
	echo "would install $RULE_FILE (valid):"
	cat "$TMP"
	exit 0
fi

install -m 0440 -o root -g wheel "$TMP" "$RULE_FILE"
echo "installed $RULE_FILE:"
cat "$RULE_FILE"
