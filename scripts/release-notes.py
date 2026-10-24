#!/usr/bin/env python3
"""Prints GitHub release notes for a version from CHANGELOG.md."""
import os
import re
import sys

version = sys.argv[1]
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
text = open(os.path.join(root, "CHANGELOG.md"), encoding="utf-8").read()
m = re.search(rf"^## \[?{re.escape(version)}\]?.*?$(.*?)(?=^## |\Z)", text, re.S | re.M)
body = m.group(1).strip() if m else "See CHANGELOG.md."

print(f"""{body}

### Install / Cài đặt
1. Install [macFUSE](https://macfuse.github.io/) and allow its system extension (Apple silicon: kernel extensions must be allowed in Startup Security Utility — the same requirement as Paragon NTFS).
2. Open the DMG and drag **XT NTFS** to Applications.
3. The app is not notarized by Apple: the first time, right-click the app → **Open**, or allow it in System Settings → Privacy & Security → **Open Anyway**.
4. In XT NTFS, click **XT NTFS** at the bottom of the sidebar → **Install Engine…**.

Updates are delivered inside the app (Sparkle, EdDSA-signed).
""")
