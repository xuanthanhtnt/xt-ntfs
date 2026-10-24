#!/usr/bin/env python3
"""Signs a release DMG with the Sparkle EdDSA key and writes appcast.xml.

usage: make-appcast.py <dmg> <version> <build> <download-url> <out-appcast.xml>
The private key (base64 32-byte seed, as exported by Sparkle's generate_keys)
is read from the SPARKLE_ED_PRIVATE_KEY environment variable.
"""
import base64
import email.utils
import os
import sys
from xml.sax.saxutils import escape

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization


def main() -> int:
    dmg, version, build, url, out = sys.argv[1:6]
    secret = os.environ.get("SPARKLE_ED_PRIVATE_KEY", "").strip()
    if not secret:
        print("SPARKLE_ED_PRIVATE_KEY is not set", file=sys.stderr)
        return 1
    seed = base64.b64decode(secret)
    if len(seed) != 32:
        print("unexpected private key length", file=sys.stderr)
        return 1
    key = Ed25519PrivateKey.from_private_bytes(seed)
    pub = base64.b64encode(key.public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw)).decode()
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    with open(os.path.join(root, "Resources", "sparkle_public_key.txt")) as f:
        expected = f.read().strip()
    if pub != expected:
        print("private key does not match Resources/sparkle_public_key.txt", file=sys.stderr)
        return 1

    with open(dmg, "rb") as f:
        data = f.read()
    signature = base64.b64encode(key.sign(data)).decode()
    key.public_key().verify(base64.b64decode(signature), data)

    notes = f"https://github.com/xuanthanhtnt/xt-ntfs/releases/tag/v{version}"
    xml = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>XT NTFS</title>
    <link>https://xuanthanhtnt.github.io/xt-ntfs/</link>
    <description>XT NTFS updates</description>
    <language>en</language>
    <item>
      <title>Version {escape(version)}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{escape(build)}</sparkle:version>
      <sparkle:shortVersionString>{escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>{escape(notes)}</sparkle:releaseNotesLink>
      <enclosure url="{escape(url)}" length="{len(data)}" type="application/octet-stream" sparkle:edSignature="{signature}"/>
    </item>
  </channel>
</rss>
"""
    with open(out, "w") as f:
        f.write(xml)
    print(f"appcast written: {out} ({len(data)} bytes signed)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
