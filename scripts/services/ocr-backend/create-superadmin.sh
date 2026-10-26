#!/usr/bin/env bash
# Create the first superadmin in shared without saving credentials in a Kubernetes Secret.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
command -v nano >/dev/null 2>&1 || { printf 'nano tidak ditemukan\n' >&2; exit 1; }

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/superadmin-shared.XXXXXX")"
trap 'rm -rf -- "$WORK_DIR"' EXIT
CREDS_FILE="$WORK_DIR/superadmin.env"
printf '%s\n' \
  '# Isi plain text tanpa tanda kutip; file sementara dihapus setelah selesai.' \
  'SUPERADMIN_EMAIL=' \
  'SUPERADMIN_PASSWORD=' > "$CREDS_FILE"
chmod 600 "$CREDS_FILE"
nano "$CREDS_FILE"

REMOTE_PY='import asyncio, os, sys
from scripts.create_superadmin import main
required = {"SUPERADMIN_EMAIL", "SUPERADMIN_PASSWORD"}
values = {}
for raw in sys.stdin:
    line = raw.rstrip("\r\n")
    if not line or line.startswith("#"):
        continue
    key, separator, value = line.partition("=")
    if not separator or key not in required or key in values:
        raise SystemExit("File hanya boleh berisi SUPERADMIN_EMAIL dan SUPERADMIN_PASSWORD.")
    values[key] = value
if set(values) != required:
    raise SystemExit("Isi SUPERADMIN_EMAIL dan SUPERADMIN_PASSWORD di nano.")
if len(values["SUPERADMIN_PASSWORD"]) < 12:
    raise SystemExit("Password minimal 12 karakter.")
os.environ.update(values)
raise SystemExit(asyncio.run(main()))'

"$ROOT_DIR/scripts/kube.sh" --env shared -- kubectl exec -i \
  -n bribrain-ocr-nilam deploy/ms-bribrain-nilam-ocr-orchestrator-api -- \
  python -c "$REMOTE_PY" < "$CREDS_FILE"
