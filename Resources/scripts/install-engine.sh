#!/bin/bash
# Installs (or updates) the XT NTFS helper and engine. Run as root:
#   install-engine.sh "/Applications/XT NTFS.app"
set -euo pipefail

APP="${1:?usage: install-engine.sh <path to XT NTFS.app>}"
RES="$APP/Contents/Resources"
LABEL="com.xuanthanhtnt.xtntfs.helper"
SUPPORT="/Library/Application Support/XTNTFS"
HELPER="/Library/PrivilegedHelperTools/$LABEL"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
LOG="/Library/Logs/XTNTFS.log"

if [ "$(id -u)" != 0 ]; then echo "This script must run as root." >&2; exit 1; fi
if [ ! -x "$APP/Contents/MacOS/xtntfsd" ] || [ ! -x "$RES/engine/ntfs-3g" ]; then
  echo "The app bundle is incomplete: $APP" >&2
  exit 1
fi

# Stop the running helper (NTFS volumes stay mounted: ntfs-3g runs on its own).
launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
for _ in $(seq 1 40); do
  launchctl print "system/$LABEL" >/dev/null 2>&1 || break
  sleep 0.25
done

mkdir -p "$SUPPORT" /Library/PrivilegedHelperTools

# Engine binaries: stage then swap, so running ntfs-3g processes keep theirs.
rm -rf "$SUPPORT/engine.new"
mkdir -p "$SUPPORT/engine.new"
cp -X "$RES/engine/"* "$SUPPORT/engine.new/"
chown -R root:wheel "$SUPPORT/engine.new"
chmod 755 "$SUPPORT/engine.new"
find "$SUPPORT/engine.new" -type f -exec chmod 755 {} +
chmod 644 "$SUPPORT/engine.new/NTFS3G_VERSION" 2>/dev/null || true
rm -rf "$SUPPORT/engine.old"
if [ -d "$SUPPORT/engine" ]; then mv "$SUPPORT/engine" "$SUPPORT/engine.old"; fi
mv "$SUPPORT/engine.new" "$SUPPORT/engine"
rm -rf "$SUPPORT/engine.old"

if [ -f "$RES/NTFSVolume.icns" ]; then
  cp -X "$RES/NTFSVolume.icns" "$SUPPORT/VolumeIcon.icns"
  chmod 644 "$SUPPORT/VolumeIcon.icns"
fi

install -m 755 -o root -g wheel "$APP/Contents/MacOS/xtntfsd" "$HELPER"
xattr -cr "$SUPPORT" 2>/dev/null || true
xattr -c "$HELPER" 2>/dev/null || true

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$HELPER</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>AbandonProcessGroup</key>
	<true/>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>StandardOutPath</key>
	<string>$LOG</string>
	<key>StandardErrorPath</key>
	<string>$LOG</string>
	<key>AssociatedBundleIdentifiers</key>
	<array>
		<string>com.xuanthanhtnt.xtntfs</string>
	</array>
</dict>
</plist>
EOF
chown root:wheel "$PLIST"
chmod 644 "$PLIST"

# Keep the log small.
if [ -f "$LOG" ] && [ "$(stat -f %z "$LOG")" -gt 5242880 ]; then
  mv -f "$LOG" "$LOG.old"
fi
touch "$LOG"
chmod 644 "$LOG"

launchctl bootstrap system "$PLIST"
launchctl enable "system/$LABEL" >/dev/null 2>&1 || true
echo "XT NTFS engine installed."
