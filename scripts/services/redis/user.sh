#!/usr/bin/env bash
# Buat atau rotasi user ACL sebuah team di Redis bersama. Menjalankan ulang untuk user yang sama = rotasi
# password (lalu restart pod team itu). Password disimpan di Secret redis-<user> di namespace team (REDIS_URL,
# REDIS_HOST, REDIS_PORT, REDIS_USERNAME, REDIS_PASSWORD); Secret ACL Redis hanya menyimpan hash-nya.
#
# Usage:
#   ./scripts/services/redis/user.sh <user> --keys '<pola key...>' --to <namespace team> [--env shared]
#
# Contoh:
#   ./scripts/services/redis/user.sh nilam-ocr --env shared --to bribrain-ocr-nilam --keys 'ocr ocr:* arq:* datahub:*'
#   ./scripts/services/redis/user.sh team-b --env shared --to team-b --keys 'team-b:*'
source "$(dirname "${BASH_SOURCE[0]}")/../../_lib.sh"
DEPLOY_ENV="${DEPLOY_ENV:-dev}"
USER_NAME="" KEYS="" TO_NS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -e|--env) [[ $# -ge 2 ]] || die "--env butuh nilai"; DEPLOY_ENV="$2"; shift 2 ;;
    --keys) [[ $# -ge 2 ]] || die "--keys butuh nilai"; KEYS="$2"; shift 2 ;;
    --to) [[ $# -ge 2 ]] || die "--to butuh nilai"; TO_NS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "opsi tidak dikenal: $1" ;;
    *) [[ -z "$USER_NAME" ]] || die "user disebut dua kali"; USER_NAME="$1"; shift ;;
  esac
done
[[ "$USER_NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { usage; die "nama user wajib: huruf kecil, angka, '-'"; }
[[ "$USER_NAME" != default && "$USER_NAME" != admin ]] || die "user $USER_NAME dikelola script ini sendiri"
[[ -n "$KEYS" && -n "$TO_NS" ]] || { usage; die "--keys dan --to wajib"; }

read -r -a PATTERNS <<< "$KEYS"
key_rules=""
for k in "${PATTERNS[@]}"; do
  # A leading wildcard ('*', '*:x', '?x') would reach other teams' keys.
  [[ "$k" =~ ^[A-Za-z0-9] ]] || die "pola key '$k' harus diawali huruf/angka, bukan wildcard"
  key_rules="$key_rules ~$k"
done

load_env
require REDIS_RELEASE REDIS_NAMESPACE REDIS_SECRET
NAMESPACE="$REDIS_NAMESPACE"
need_tools gcloud kubectl openssl
gke_connect
ensure_namespace
kubectl --context "$KUBE_CONTEXT" get namespace "$TO_NS" >/dev/null 2>&1 || die "namespace team $TO_NS belum ada"

sha256() { printf '%s' "$1" | openssl dgst -sha256 | awk '{print $NF}'; }

acl="$WORK_DIR/users.acl"
if kc get secret "$REDIS_SECRET" >/dev/null 2>&1; then
  kc get secret "$REDIS_SECRET" -o jsonpath='{.data.users\.acl}' | base64 -d > "$acl"
  kc get secret "$REDIS_SECRET" -o jsonpath='{.data.ADMIN_PASSWORD}' | base64 -d > "$WORK_DIR/ADMIN_PASSWORD"
else
  : > "$acl"
  printf '%s' "$(openssl rand -hex 32)" > "$WORK_DIR/ADMIN_PASSWORD"
fi
pw="$(openssl rand -hex 32)"
hash="$(sha256 "$pw")"

# default and admin are rewritten every run, so a hand edit can never leave the default user open.
{
  echo "user default on nopass resetkeys resetchannels -@all +ping"
  echo "user admin on #$(sha256 "$(cat "$WORK_DIR/ADMIN_PASSWORD")") ~* &* +@all"
  grep -vE "^user (default|admin|$USER_NAME) " "$acl" || true
  # INFO is @dangerous but arq needs it at worker startup.
  echo "user $USER_NAME on #$hash resetkeys$key_rules resetchannels +@all -@dangerous +info"
} > "$acl.new"

kc create secret generic "$REDIS_SECRET" \
  --from-file=users.acl="$acl.new" --from-file=ADMIN_PASSWORD="$WORK_DIR/ADMIN_PASSWORD" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
log "ACL $REDIS_NAMESPACE/$REDIS_SECRET: user $USER_NAME ->$key_rules"

# Redis first, team Secret second: pods restarted on the new password must find it already loaded.
pod="$REDIS_RELEASE-0"
if kc get pod "$pod" >/dev/null 2>&1; then
  log "menunggu Secret ACL sampai di pod $pod (kubelet, bisa sampai ~2 menit)"
  for _ in $(seq 60); do
    kc exec "$pod" -c redis -- grep -q "$hash" /etc/redis/users.acl 2>/dev/null && break
    sleep 3
  done
  kc exec "$pod" -c redis -- grep -q "$hash" /etc/redis/users.acl || die "ACL baru belum sampai di pod; jalankan ulang"
  kc exec "$pod" -c redis -- sh -c 'REDISCLI_AUTH="$ADMIN_PASSWORD" redis-cli --user admin ACL LOAD' | grep -q OK \
    || die "ACL LOAD gagal; cek 'kubectl logs $pod'"
  log "ACL dimuat ulang tanpa restart Redis"
else
  log "pod $pod belum ada; ACL dimuat saat Redis start (./deploy.sh redis <tag>)"
fi

# The Service name equals the release name: the chart is called redis and the release contains it.
host="$REDIS_RELEASE.$REDIS_NAMESPACE.svc.cluster.local"
printf '%s' "$pw" > "$WORK_DIR/REDIS_PASSWORD"
printf '%s' "redis://$USER_NAME:$pw@$host:6379/0" > "$WORK_DIR/REDIS_URL"
kubectl --context "$KUBE_CONTEXT" -n "$TO_NS" create secret generic "redis-$USER_NAME" \
  --from-literal=REDIS_HOST="$host" --from-literal=REDIS_PORT=6379 --from-literal=REDIS_USERNAME="$USER_NAME" \
  --from-file=REDIS_PASSWORD="$WORK_DIR/REDIS_PASSWORD" --from-file=REDIS_URL="$WORK_DIR/REDIS_URL" \
  --dry-run=client -o yaml | kubectl --context "$KUBE_CONTEXT" -n "$TO_NS" apply -f - >/dev/null
log "selesai: Secret $TO_NS/redis-$USER_NAME. Bila ini rotasi, restart pod team itu."
