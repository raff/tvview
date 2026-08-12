#!/bin/sh
# Removes the sudoers.d rule installed by install-vpn-helper.sh. After this,
# vpnhelper goes back to prompting via macOS's admin-password dialog
# (osascript) every time, same as before that rule ever existed.

set -eu

if [ "$(id -u)" -ne 0 ]; then
	echo "run this with sudo: sudo $0" >&2
	exit 1
fi

RULE_FILE=/etc/sudoers.d/tvview-vpnhelper
if [ -e "$RULE_FILE" ]; then
	rm -f "$RULE_FILE"
	echo "removed $RULE_FILE"
else
	echo "$RULE_FILE not present, nothing to do"
fi
