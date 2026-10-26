#!/usr/bin/env bash
# Tampilkan env sebuah Secret, atau env yang benar-benar dilihat container sebuah Deployment (Secret envFrom +
# env eksplisit + nilai chart). Nilai rahasia (nama berisi KEY, SECRET, PASSWORD, TOKEN, ...) dan password di
# dalam URL disamarkan, kecuali dengan --reveal. Hasilnya hanya tampil di terminal; tidak ada yang disimpan.
#
# Usage:
#   ./scripts/env.sh [--env dev] [-n <namespace>] [--reveal] [<secret> | deploy/<nama>]
#
# Contoh:
#   ./scripts/env.sh --env shared                                                  # Secret $BACKEND_SECRET
#   ./scripts/env.sh --env shared deploy/ms-bribrain-nilam-ocr-orchestrator-api    # env efektif pod api
#   ./scripts/env.sh --env shared redis-nilam-ocr
#   ./scripts/env.sh --env shared --reveal | grep CALLBACK                         # nilai asli
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

DEPLOY_ENV="${DEPLOY_ENV:-dev}"
NAMESPACE="" REVEAL="" TARGET=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -e|--env) [[ $# -ge 2 ]] || die "--env butuh nilai"; DEPLOY_ENV="$2"; shift 2 ;;
    -n|--namespace) [[ $# -ge 2 ]] || die "--namespace butuh nilai"; NAMESPACE="$2"; shift 2 ;;
    --reveal) REVEAL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "opsi tidak dikenal: $1" ;;
    *) [[ -z "$TARGET" ]] || die "target disebut dua kali: $TARGET dan $1"; TARGET="$1"; shift ;;
  esac
done

load_env
NAMESPACE="${NAMESPACE:-${BACKEND_NAMESPACE:-}}"
TARGET="${TARGET:-${BACKEND_SECRET:-}}"
[[ -n "$NAMESPACE" ]] || die "namespace kosong; pakai -n <namespace>"
[[ -n "$TARGET" ]] || die "target kosong; sebut nama Secret atau deploy/<nama>"
need_tools gcloud kubectl
gke_connect

if [[ "$TARGET" == deploy/* ]]; then
  # Kubernetes adds <SVC>_SERVICE_HOST/_PORT and <SVC>_PORT_* for every Service in the namespace: noise, dropped.
  kc exec "$TARGET" -- env \
    | grep -vE '^[A-Z0-9_]+_(SERVICE_HOST|SERVICE_PORT(_[A-Z0-9_]+)?)=|^[A-Z0-9_]+_PORT=(tcp|udp)://|^[A-Z0-9_]+_PORT_[0-9]+_(TCP|UDP)'
else
  kc get secret "$TARGET" -o go-template='{{range $k, $v := .data}}{{$k}}={{$v | base64decode}}{{"\n"}}{{end}}'
fi | sort | awk -v reveal="$REVEAL" '
  {
    i = index($0, "="); if (i == 0) { print; next }
    k = substr($0, 1, i - 1); v = substr($0, i + 1)
    if (!reveal && v != "") {
      if (k ~ /(KEY|SECRET|PASSWORD|PASSWD|TOKEN|CREDENTIAL|PRIVATE)/) {
        # A 4-character prefix tells keys apart (ocr_840e...) without giving away short passwords.
        v = (length(v) >= 16 ? substr(v, 1, 4) : "") "*** (" length(v) " karakter)"
      } else if (match(v, /:\/\/[^:\/@]+:[^@]+@/)) {
        m = substr(v, RSTART, RLENGTH); j = index(substr(m, 4), ":")
        v = substr(v, 1, RSTART - 1) substr(m, 1, 3 + j) "***@" substr(v, RSTART + RLENGTH)
      }
    }
    print k "=" v
  }'
