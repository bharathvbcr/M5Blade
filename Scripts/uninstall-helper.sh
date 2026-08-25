#!/bin/bash
# Removes the helper and returns every fan to macOS control.
set -uo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "This script must run as root. Try: sudo $0" >&2
  exit 1
fi

# The SMC writes outlive the helper process, so the only guaranteed way to
# hand the fans back is to write `auto` directly — which is what the bundled
# smcfan tool is for. It lives next to this script inside the app bundle; the
# old path here (/usr/local/libexec/smcfan) was never installed by anything,
# so the restore step silently never ran and fans stayed pinned at their last
# manual target after an uninstall.
SMCFOX=""
for candidate in "$(dirname "$0")/smcfan" "$(dirname "$0")/../Resources/smcfan"; do
  if [ -x "$candidate" ]; then SMCFOX="$candidate"; break; fi
done

echo "Restoring automatic fan control…"
if [ -n "$SMCFOX" ]; then
  if "$SMCFOX" auto; then
    if "$SMCFOX" fans | grep -qi "auto"; then
      echo "Fans confirmed back under macOS control."
    else
      echo "WARNING: could not confirm every fan returned to automatic control." >&2
      echo "Run: sudo \"$SMCFOX\" fans   — and check the mode column." >&2
    fi
  else
    echo "WARNING: the direct restore write failed. Fans may still be pinned." >&2
    echo "If the helper was driving them, reinstall it once and uninstall again," >&2
    echo "or run: sudo \"$SMCFOX\" auto   manually." >&2
  fi
else
  echo "NOTE: smcfan not found beside this script; relying on the helper's" >&2
  echo "shutdown release instead. Verify with: smcfan fans (from the app bundle)." >&2
fi

echo "Stopping helper…"
launchctl bootout system/com.m5blade.helper 2>/dev/null || true
launchctl bootout system/com.fancontrol.helper 2>/dev/null || true

echo "Removing files…"
rm -f /Library/LaunchDaemons/com.m5blade.helper.plist
rm -f /Library/LaunchDaemons/com.fancontrol.helper.plist
rm -f /usr/local/libexec/m5bladed
rm -f /usr/local/libexec/fancontrold
rm -rf "/Library/Application Support/M5Blade"
rm -rf "/Library/Application Support/FanControl"

# Honest ending: the restore either verified above or it did not. The old
# unconditional success line printed over a possible pinned-fan failure.
if [ -n "$SMCFOX" ] && "$SMCFOX" fans | grep -qi "auto"; then
  echo "Done. Fans are back under macOS control."
else
  echo "Done removing files — but fan control was NOT verified restored. See the warnings above." >&2
fi
