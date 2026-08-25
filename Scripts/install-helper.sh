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
  echo "This script must run as root. Try: sudo $0 <path-to-M5Blade.app>" >&2
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

HELPER_SRC="$APP_PATH/Contents/Resources/m5bladed"
PLIST_SRC="$APP_PATH/Contents/Resources/com.m5blade.helper.plist"
HELPER_DST="/usr/local/libexec/m5bladed"
PLIST_DST="/Library/LaunchDaemons/com.m5blade.helper.plist"
SUPPORT_DIR="/Library/Application Support/M5Blade"
REQUIREMENT_FILE="$SUPPORT_DIR/client.requirement"

echo "Installing from: $APP_PATH"

echo "  · deriving the app's code signing requirement"
CDHASH="$(codesign -dvvv "$APP_PATH" 2>&1 | awk -F'=' '/^CDHash/{print $2; exit}')"
if [ -z "$CDHASH" ]; then
  echo "Could not read the app's cdhash. Is it signed? Run 'make app' first." >&2
  exit 1
fi
REQUIREMENT="identifier \"com.m5blade.app\" and cdhash H\"$CDHASH\""
echo "    $REQUIREMENT"

echo "  · cleaning legacy helpers if present"
if launchctl print system/com.fancontrol.helper >/dev/null 2>&1; then
  launchctl bootout system/com.fancontrol.helper 2>/dev/null || true
  rm -f /Library/LaunchDaemons/com.fancontrol.helper.plist
  rm -f /usr/local/libexec/fancontrold
fi

mkdir -p /usr/local/libexec
mkdir -p "$SUPPORT_DIR"

# Replacing a file requires write access to its *directory*, so root:wheel on
# the files protects nothing if a pre-existing bad-ownership directory lets any
# local process swap them: client.requirement pins who may talk to a root
# control channel, and the LaunchDaemon re-executes its binary as root.
for dir in /usr/local/libexec "$SUPPORT_DIR"; do
  if [ -d "$dir" ]; then
    OWNER="$(stat -f '%Su:%Sg' "$dir")"
    if [ "$OWNER" != "root:wheel" ]; then
      echo "Refusing: $dir is owned by $OWNER, expected root:wheel." >&2
      echo "Fix it first: sudo chown root:wheel \"$dir\" && sudo chmod 755 \"$dir\"" >&2
      exit 1
    fi
    chmod 755 "$dir"
  else
    chown root:wheel "$dir"
    chmod 755 "$dir"
  fi
done

printf '%s' "$REQUIREMENT" > "$REQUIREMENT_FILE.tmp.$$"
chown root:wheel "$REQUIREMENT_FILE.tmp.$$"
chmod 644 "$REQUIREMENT_FILE.tmp.$$"

# Stage everything BEFORE stopping the running helper. Booting out first and
# failing halfway used to leave no daemon loaded and nothing managing the fans
# until someone re-ran this script by hand; KeepAlive cannot resurrect a job
# that bootout removed from launchd's domain.
install -m 755 -o root -g wheel "$HELPER_SRC" "$HELPER_DST.new.$$"
install -m 644 -o root -g wheel "$PLIST_SRC" "$PLIST_DST.new.$$"

cleanup() {
  rm -f "$HELPER_DST.new.$$" "$PLIST_DST.new.$$" "$REQUIREMENT_FILE.tmp.$$"
}
trap cleanup EXIT

echo "  · swapping in the new helper"
WAS_RUNNING=0
if launchctl print system/com.m5blade.helper >/dev/null 2>&1; then
  WAS_RUNNING=1
  launchctl bootout system/com.m5blade.helper 2>/dev/null || true
  sleep 1
fi

mv "$HELPER_DST.new.$$" "$HELPER_DST"
mv "$PLIST_DST.new.$$" "$PLIST_DST"
mv "$REQUIREMENT_FILE.tmp.$$" "$REQUIREMENT_FILE"

echo "  · loading"
launchctl bootstrap system "$PLIST_DST"
sleep 1

# Registration is not liveness: a crash-looping job stays registered under
# KeepAlive while refusing every connection. Check for an actual process too.
print_ok=0
pgrep_ok=0
launchctl print system/com.m5blade.helper >/dev/null 2>&1 && print_ok=1
pgrep -x m5bladed >/dev/null 2>&1 && pgrep_ok=1

if [ "$print_ok" -eq 1 ] && [ "$pgrep_ok" -eq 1 ]; then
  trap - EXIT
  echo ""
  echo "Helper installed and running."
  echo "Log: /var/log/m5bladed.log"
  echo ""
  echo "The requirement above pins the helper to THIS build of the app."
  echo "Rebuild the app and you must re-run this script."
elif [ "$print_ok" -eq 1 ] && [ "$WAS_RUNNING" -eq 1 ]; then
  # A previous instance was healthy; this one exited immediately after
  # bootstrap. KeepAlive may still settle it — but do not claim success.
  echo "Helper registered but no running process detected yet." >&2
  echo "It may still be starting; check: pgrep m5bladed ; tail /var/log/m5bladed.log" >&2
  exit 1
else
  echo "Helper failed to start. Check /var/log/m5bladed.log" >&2
  exit 1
fi
