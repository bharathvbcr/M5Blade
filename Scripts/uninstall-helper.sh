#!/bin/bash
# Removes the helper and returns every fan to macOS control.
set -uo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "This script must run as root. Try: sudo $0" >&2
  exit 1
fi

echo "Restoring automatic fan control…"
if [ -x /usr/local/libexec/smcfan ]; then
  /usr/local/libexec/smcfan auto || true
fi

echo "Stopping helper…"
launchctl bootout system/com.fancontrol.helper 2>/dev/null || true

echo "Removing files…"
rm -f /Library/LaunchDaemons/com.fancontrol.helper.plist
rm -f /usr/local/libexec/fancontrold
rm -rf "/Library/Application Support/FanControl"

echo "Done. Fans are back under macOS control."
