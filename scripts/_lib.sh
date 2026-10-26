#!/usr/bin/env bash
# Shared helpers for service and cluster scripts. Sourced, not run.
#
# Value precedence: shell env > .env (secrets, not committed) > environments/<env>.env.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { echo ">> $*" >&2; }
die() { echo "!! $*" >&2; exit 1; }

# The calling script's header comment is its help text.
usage() { awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0" >&2; }

parse_args() {
  TAG=""
  DEPLOY_ENV="${DEPLOY_ENV:-dev}"
  DRY_RUN=""
  EXTRA_HELM_ARGS=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -e|--env) [[ $# -ge 2 ]] || die "--env butuh nilai"; DEPLOY_ENV="$2"; shift 2 ;;
      --dry-run) DRY_RUN=1; shift ;;
      -h|--help) usage; exit 0 ;;
      --) shift; EXTRA_HELM_ARGS=("$@"); break ;;
      -*) die "opsi tidak dikenal: $1" ;;
      *) [[ -z "$TAG" ]] || die "tag disebut dua kali: $TAG dan $1"; TAG="$1"; shift ;;
    esac
  done
  # No default tag: a moving tag deploys whatever was pushed last and cannot be rolled back.
  [[ -n "$TAG" ]] || { usage; die "tag image wajib (git short sha yang sudah ada di Nexus)"; }
}

load_env_file() {
  local file="$1" line key val
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"; key="${key//[[:space:]]/}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    val="${line#*=}"; val="${val%$'\r'}"
    val="${val#\"}"; val="${val%\"}"; val="${val#\'}"; val="${val%\'}"
    [[ -n "${!key:-}" ]] && continue
    export "$key=$val"
  done < "$file"
}

load_env() {
  local env_file="$ROOT_DIR/environments/$DEPLOY_ENV.env"
  [[ -f "$env_file" ]] || die "environment '$DEPLOY_ENV' tidak ada: $env_file (salin dari $env_file.example)"
  load_env_file "$ROOT_DIR/.env"
  load_env_file "$env_file"
  ENV_VALUES_DIR="$ROOT_DIR/environments/$DEPLOY_ENV"
  require GKE_PROJECT GKE_REGION GKE_CLUSTER NEXUS_REGISTRY NEXUS_PATH PULL_SECRET
}

require() {
  local n
  for n in "$@"; do
    [[ -n "${!n:-}" ]] || die "$n kosong (environments/$DEPLOY_ENV.env, .env, atau env shell)"
  done
}

need_tools() {
  local t missing=""
  for t in "$@"; do command -v "$t" >/dev/null 2>&1 || missing="$missing $t"; done
  [[ -z "$missing" ]] || die "perkakas belum terpasang:$missing"
}

# Each run gets its own kubeconfig: ~/.kube/config is never read or changed, and a tunnel's proxy-url
# never leaks into it.
gke_connect() {
  local opts=(--region "$GKE_REGION" --project "$GKE_PROJECT")
  [[ -n "${IMPERSONATE_SA:-}" ]] && opts+=(--impersonate-service-account="$IMPERSONATE_SA")
  [[ -n "${GKE_BASTION:-}" ]] && opts+=(--internal-ip)
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/deploy-ocr.XXXXXX")"
  trap cleanup EXIT
  export KUBECONFIG="$WORK_DIR/kubeconfig"
  log "kredensial GKE $GKE_CLUSTER ($GKE_PROJECT, $GKE_REGION)"
  local err
  err="$(gcloud container clusters get-credentials "$GKE_CLUSTER" "${opts[@]}" 2>&1 >/dev/null)" \
    || die "get-credentials gagal sebagai '$(gcloud config get account 2>/dev/null)': $err"
  KUBE_CONTEXT="gke_${GKE_PROJECT}_${GKE_REGION}_${GKE_CLUSTER}"
  # Run on the bastion itself, the private endpoint is reachable without a tunnel.
  [[ -z "${GKE_BASTION:-}" || "$GKE_BASTION" == "$(hostname -s)" ]] || open_tunnel
}

# Private control plane: SOCKS tunnel over IAP through a bastion inside its authorized networks.
open_tunnel() {
  local port attempt i
  require GKE_BASTION_ZONE
  # IAP + sshd on the bastion usually answer in ~5s but now and then hang in the banner exchange; a fresh
  # attempt gets through.
  for attempt in 1 2 3; do
    port=$((20000 + RANDOM % 10000))
    log "tunnel lewat bastion $GKE_BASTION (IAP, localhost:$port, percobaan $attempt)"
    gcloud compute ssh "$GKE_BASTION" --zone "$GKE_BASTION_ZONE" --project "${GKE_BASTION_PROJECT:-$GKE_PROJECT}" \
      --tunnel-through-iap --quiet -- -N -D "127.0.0.1:$port" \
      -o ExitOnForwardFailure=yes -o BatchMode=yes -o ServerAliveInterval=30 >"$WORK_DIR/tunnel.log" 2>&1 &
    TUNNEL_PID=$!
    for i in $(seq 25); do
      if nc -z 127.0.0.1 "$port" 2>/dev/null; then
        kubectl config set "clusters.$KUBE_CONTEXT.proxy-url" "socks5://127.0.0.1:$port" >/dev/null
        return 0
      fi
      kill -0 "$TUNNEL_PID" 2>/dev/null || break
      sleep 1
    done
    close_tunnel
  done
  die "tunnel ke $GKE_BASTION gagal 3 kali: $(tail -1 "$WORK_DIR/tunnel.log")"
}

close_tunnel() {
  # gcloud does not take its ssh child down with it.
  [[ -n "${TUNNEL_PID:-}" ]] || return 0
  pkill -P "$TUNNEL_PID" 2>/dev/null || true
  kill "$TUNNEL_PID" 2>/dev/null || true
  wait "$TUNNEL_PID" 2>/dev/null || true
  TUNNEL_PID=""
}

cleanup() {
  close_tunnel
  rm -rf "${WORK_DIR:-}"
}

kc() { kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" "$@"; }

ensure_namespace() {
  kubectl --context "$KUBE_CONTEXT" get namespace "$NAMESPACE" >/dev/null 2>&1 \
    || kubectl --context "$KUBE_CONTEXT" create namespace "$NAMESPACE" >/dev/null
}

# Refreshed on every deploy when credentials are given, so a rotated Nexus password only needs .env updated.
ensure_pull_secret() {
  if [[ -n "${NEXUS_USERNAME:-}" && -n "${NEXUS_PASSWORD:-}" ]]; then
    kc create secret docker-registry "$PULL_SECRET" \
      --docker-server="$NEXUS_REGISTRY" \
      --docker-username="$NEXUS_USERNAME" \
      --docker-password="$NEXUS_PASSWORD" \
      --dry-run=client -o yaml | kc apply -f - >/dev/null
    log "Secret $PULL_SECRET diperbarui"
  else
    kc get secret "$PULL_SECRET" >/dev/null 2>&1 \
      || die "Secret $PULL_SECRET belum ada di $NAMESPACE; isi NEXUS_USERNAME dan NEXUS_PASSWORD di .env"
  fi
}

ensure_secret() {
  kc get secret "$1" >/dev/null 2>&1 || die "Secret aplikasi $1 belum ada di $NAMESPACE (lihat README 'Secret aplikasi')"
}

# Fails here, in seconds, instead of as ImagePullBackOff after helm's timeout.
check_image() {
  [[ -n "${SKIP_IMAGE_CHECK:-}" ]] && return 0
  need_tools docker
  local out
  out="$(docker buildx imagetools inspect "$1" 2>&1 >/dev/null)" \
    || die "image $1 tidak bisa dibaca dari Nexus (tag belum di-push, belum 'docker login $NEXUS_REGISTRY', atau VPN putus): ${out##*$'\n'}"
}

# helm refuses objects owned by another release only after it has started; this names them up front.
check_owners() {
  local release="$1" kind name owner
  while read -r kind name; do
    owner="$(kc get "$kind" "$name" -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null)" || continue
    [[ "$owner" == "$release" ]] \
      || die "$kind/$name sudah ada di $NAMESPACE dan dimiliki ${owner:-objek non-Helm}, bukan $release. Lihat README 'Migrasi dari chart lama'."
  done < <(helm template "$release" "${HELM_ARGS[@]}" -n "$NAMESPACE" \
             | awk '/^kind:/{k=$2} /^metadata:/{m=1; next} m && /^  name:/{print k, $2; m=0}')
}

rollback_flag() {
  case "$(helm version --short 2>/dev/null)" in
    v3.*) echo "--atomic" ;;
    *) echo "--rollback-on-failure" ;;
  esac
}

# deploy_component <release> <chart> <image> [extra helm args...]
deploy_component() {
  local release="$1" chart="$2" image="$3"
  shift 3
  local ref="$NEXUS_REGISTRY/$NEXUS_PATH/$image:$TAG"
  HELM_ARGS=(
    "$ROOT_DIR/charts/$chart"
    -f "$ENV_VALUES_DIR/$chart.yaml"
    --set "image.registry=$NEXUS_REGISTRY"
    --set "image.repository=$NEXUS_PATH/$image"
    --set-string "image.tag=$TAG"
    --set "imagePullSecrets[0].name=$PULL_SECRET"
    "$@"
    ${EXTRA_HELM_ARGS[@]+"${EXTRA_HELM_ARGS[@]}"}
  )
  [[ -f "$ENV_VALUES_DIR/$chart.yaml" ]] || die "values environment tidak ada: $ENV_VALUES_DIR/$chart.yaml"

  log "release  : $release (chart $chart, env $DEPLOY_ENV)"
  log "image    : $ref"
  log "target   : $GKE_CLUSTER / $GKE_PROJECT / ns $NAMESPACE"

  if [[ -n "$DRY_RUN" ]]; then
    need_tools helm
    helm template "$release" "${HELM_ARGS[@]}" -n "$NAMESPACE"
    return
  fi

  need_tools gcloud kubectl helm
  check_image "$ref"
  gke_connect
  ensure_namespace
  ensure_pull_secret
  [[ -z "${APP_SECRET:-}" ]] || ensure_secret "$APP_SECRET"
  check_owners "$release"

  log "helm upgrade --install $release"
  helm --kube-context "$KUBE_CONTEXT" upgrade --install "$release" "${HELM_ARGS[@]}" \
    -n "$NAMESPACE" --wait --timeout "${HELM_TIMEOUT:-10m}" --history-max 10 "$(rollback_flag)"
  log "selesai: $release $TAG. Rollback: jalankan script ini lagi dengan tag sebelumnya"
}
