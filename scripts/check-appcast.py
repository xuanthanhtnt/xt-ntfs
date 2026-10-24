#!/usr/bin/env python3
"""Checks a Sparkle appcast against the release it points to.

usage: check-appcast.py <appcast.xml> <public-key-file>

Downloads every enclosure, checks its length and EdDSA signature with the
public key, and prints the release tag of the first enclosure
(.../releases/download/<tag>/<file>). Exits non-zero on any mismatch.
"""
import base64
import re
import sys
import urllib.request
import xml.etree.ElementTree as ET

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def main() -> int:
    appcast, keyfile = sys.argv[1:3]
    with open(keyfile) as f:
        key = Ed25519PublicKey.from_public_bytes(base64.b64decode(f.read().strip()))
    root = ET.parse(appcast).getroot()
    tags = []
    for enc in root.iter("enclosure"):
        url = enc.get("url")
        length = int(enc.get("length"))
        sig = base64.b64decode(enc.get(SPARKLE + "edSignature"))
        with urllib.request.urlopen(url, timeout=300) as r:
            data = r.read()
        if len(data) != length:
            print(f"{url}: length {len(data)} != {length}", file=sys.stderr)
            return 1
        key.verify(sig, data)  # raises on a bad signature
        m = re.search(r"/releases/download/([^/]+)/", url)
        if m:
            tags.append(m.group(1))
        print(f"ok: {url} ({length} bytes)", file=sys.stderr)
    if not tags:
        print("no release enclosure found", file=sys.stderr)
        return 1
    print(tags[0])
    return 0


if __name__ == "__main__":
    sys.exit(main())
