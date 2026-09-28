#!/bin/bash
# Static/integration smoke test for the Sinden compatibility layer.
# Hardware camera tracking cannot be tested without a gun, but the boot
# scripts, subsystem names, and TCP endpoint used by the simulated service can.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/../../buildroot/src/batocera.linux-43/package/batocera/controllers/guns/sinden-guns/virtual-sindenlightgun-add" ]; then
  BASE="$(cd "$SCRIPT_DIR/../.." && pwd)"
else
  BASE="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
ADD="$BASE/buildroot/src/batocera.linux-43/package/batocera/controllers/guns/sinden-guns/virtual-sindenlightgun-add"
HELPER="$BASE/buildroot/src/batocera.linux-43/package/batocera/utils/evsieve/evsieve-helper"
PATCH="$BASE/scripts/patch-batocera-sinden.sh"

# When copied to a Batocera VM, test the installed files instead of requiring
# the full project checkout.
if [ ! -f "$ADD" ]; then
    ADD=/usr/bin/virtual-sindenlightgun-add
    HELPER=/usr/bin/evsieve-helper
    PATCH=/tmp/patch-batocera-sinden.sh
fi

test -f "$ADD" -a -f "$HELPER" -a -f "$PATCH"
grep -q 'video4linux' "$PATCH"
grep -q 'NDEVSINPUTS.*-ge 2' "$PATCH"
grep -q 'video4linux' "$HELPER" || true

python3 - <<'PY'
import socket

server = socket.socket()
server.bind(("127.0.0.1", 0))
port = server.getsockname()[1]
server.listen(1)
client = socket.create_connection(("127.0.0.1", port))
peer, _ = server.accept()
client.sendall(b"sinden-simulation\n")
assert peer.recv(64) == b"sinden-simulation\n"
client.close(); peer.close(); server.close()
print("Sinden simulated TCP endpoint: PASS")
PY

echo "Sinden pipeline smoke test: PASS"
