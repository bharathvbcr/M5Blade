#!/bin/bash
# Installs the privileged helper as a LaunchDaemon.
#
# This exists because SMAppService needs a signing certificate we don't have.
# The SMC firmware only requires root for writes — the certificate requirement
# belongs to Apple's *install* mechanism, not to the write itself.
#
# The one thing that must not be skipped: pinning the helper's XPC listener to
# this app's code signature. Without it the Mach service is an unauthenticated
# root control channel reachable by every process on the machine.

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "This script must run as root. Try: sudo $0 <path-to-FanControl.app>" >&2
  exit 1
fi

APP_PATH="${1:-}"
if [ -z "$APP_PATH" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  APP_PATH="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi

if [ ! -d "$APP_PATH" ]; then
  echo "App bundle not found at: $APP_PATH" >&2
  exit 1
fi

HELPER_SRC="$APP_PATH/Contents/Resources/fancontrold"
PLIST_SRC="$APP_PATH/Contents/Resources/com.fancontrol.helper.plist"
HELPER_DST="/usr/local/libexec/fancontrold"
PLIST_DST="/Library/LaunchDaemons/com.fancontrol.helper.plist"
SUPPORT_DIR="/Library/Application Support/FanControl"
REQUIREMENT_FILE="$SUPPORT_DIR/client.requirement"

echo "Installing from: $APP_PATH"

echo "  · deriving the app's code signing requirement"
CDHASH="$(codesign -dvvv "$APP_PATH" 2>&1 | awk -F'=' '/^CDHash/{print $2; exit}')"
if [ -z "$CDHASH" ]; then
  echo "Could not read the app's cdhash. Is it signed? Run 'make app' first." >&2
  exit 1
fi
REQUIREMENT="identifier \"com.fancontrol.app\" and cdhash H\"$CDHASH\""
echo "    $REQUIREMENT"

mkdir -p "$SUPPORT_DIR"
printf '%s' "$REQUIREMENT" > "$REQUIREMENT_FILE"
chown root:wheel "$REQUIREMENT_FILE"
chmod 644 "$REQUIREMENT_FILE"

echo "  · installing helper to $HELPER_DST"
mkdir -p /usr/local/libexec
if launchctl print system/com.fancontrol.helper >/dev/null 2>&1; then
  launchctl bootout system/com.fancontrol.helper 2>/dev/null || true
  sleep 1
fi
install -m 755 -o root -g wheel "$HELPER_SRC" "$HELPER_DST"

echo "  · installing launchd job"
install -m 644 -o root -g wheel "$PLIST_SRC" "$PLIST_DST"

echo "  · loading"
launchctl bootstrap system "$PLIST_DST"
sleep 1

if launchctl print system/com.fancontrol.helper >/dev/null 2>&1; then
  echo ""
  echo "Helper installed and running."
  echo "Log: /var/log/fancontrold.log"
  echo ""
  echo "The requirement above pins the helper to THIS build of the app."
  echo "Rebuild the app and you must re-run this script."
else
  echo "Helper failed to start. Check /var/log/fancontrold.log" >&2
  exit 1
fi
