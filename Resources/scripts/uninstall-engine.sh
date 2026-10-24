#!/bin/bash
# Removes the XT NTFS helper and engine. Run as root.
set -uo pipefail

LABEL="com.xuanthanhtnt.xtntfs.helper"
SUPPORT="/Library/Application Support/XTNTFS"
HELPER="/Library/PrivilegedHelperTools/$LABEL"
PLIST="/Library/LaunchDaemons/$LABEL.plist"

if [ "$(id -u)" != 0 ]; then echo "This script must run as root." >&2; exit 1; fi

launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true

# Unmount volumes still served by the XT engine (ntfs-3g on macFUSE).
/sbin/mount | /usr/bin/sed -nE 's#^/dev/r?disk[0-9s]+ on (.*) \((macfuse|osxfuse).*#\1#p' |
while IFS= read -r mp; do
  /usr/sbin/diskutil unmount "$mp" >/dev/null 2>&1 || /sbin/umount -f "$mp" >/dev/null 2>&1 || true
done
sleep 1
/usr/bin/pkill -f "$SUPPORT/engine/ntfs-3g" >/dev/null 2>&1 || true

rm -f "$PLIST" "$HELPER" /var/run/com.xuanthanhtnt.xtntfs.sock
rm -rf "$SUPPORT"
echo "XT NTFS engine removed."
