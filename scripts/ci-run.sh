#!/usr/bin/env bash
# Runs a command; if it fails on GitHub Actions, the end of its output is
# also emitted as error annotations so it can be read from the checks API.
#   scripts/ci-run.sh <command> [args...]
set -uo pipefail

LOG="$(mktemp)"
"$@" 2>&1 | tee "$LOG"
status=${PIPESTATUS[0]}
if [ "$status" -ne 0 ] && [ -n "${GITHUB_ACTIONS:-}" ]; then
  python3 - "$LOG" "$*" <<'EOF'
import sys
path, cmd = sys.argv[1], sys.argv[2]
lines = open(path, errors="replace").read().splitlines()[-240:]
chunks = [lines[i:i + 30] for i in range(0, len(lines), 30)][-8:]
def esc(s):
    return s.replace("%", "%25").replace("\r", "").replace("\n", "%0A")
for n, chunk in enumerate(chunks, 1):
    body = "\n".join(chunk)
    print(f"::error title=log {n}/{len(chunks)} ({cmd[:60]})::{esc(body)}")
EOF
fi
rm -f "$LOG"
exit "$status"
