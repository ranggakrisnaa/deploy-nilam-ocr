#!/usr/bin/env bash
# Ubah satu key sebuah Secret secara interaktif: ketik nama Secret, pilih key-nya (nomor atau nama), lalu ketik
# nilai baru dua kali. Nilai tidak tampil di layar dan tidak masuk argumen proses maupun history shell.
# Pod membaca Secret lewat env hanya saat start, jadi di akhir script menawarkan restart pemakainya.
#
# Usage:
#   ./scripts/secret.sh [--env dev] [-n <namespace>]
#
# Contoh:
#   ./scripts/secret.sh --env shared                 # namespace default: $BACKEND_NAMESPACE
#   ./scripts/secret.sh --env shared -n nilam
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

DEPLOY_ENV="${DEPLOY_ENV:-dev}"
NAMESPACE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -e|--env) [[ $# -ge 2 ]] || die "--env butuh nilai"; DEPLOY_ENV="$2"; shift 2 ;;
    -n|--namespace) [[ $# -ge 2 ]] || die "--namespace butuh nilai"; NAMESPACE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "opsi tidak dikenal: $1" ;;
  esac
done

load_env
NAMESPACE="${NAMESPACE:-${BACKEND_NAMESPACE:-}}"
[[ -n "$NAMESPACE" ]] || die "namespace kosong; pakai -n <namespace>"
need_tools gcloud kubectl
gke_connect

read -r -p "Nama Secret di $NAMESPACE: " name
[[ -n "$name" ]] && kc get secret "$name" >/dev/null 2>&1 || die "Secret '$name' tidak ada di $NAMESPACE"

keys=()
while IFS= read -r k; do [[ -n "$k" ]] && keys+=("$k"); done \
  < <(kc get secret "$name" -o go-template='{{range $k, $v := .data}}{{$k}}{{"\n"}}{{end}}')
[[ ${#keys[@]} -gt 0 ]] || die "Secret $name tidak punya key"

PS3="Nomor atau nama key yang diubah: "
select key in "${keys[@]}"; do
  for k in "${keys[@]}"; do [[ "$k" == "$REPLY" ]] && key="$k"; done
  [[ -n "$key" ]] && break
done
[[ -n "${key:-}" ]] || die "tidak ada key dipilih"

read -r -s -p "Nilai baru $key: " val; echo >&2
read -r -s -p "Ulangi nilai: " again; echo >&2
[[ -n "$val" ]] || die "nilai kosong, Secret tidak diubah"
[[ "$val" == "$again" ]] || die "nilai tidak sama, Secret tidak diubah"

# printf is a builtin, so the value never shows up in ps; kubectl reads the patch from stdin.
printf '{"data":{"%s":"%s"}}' "$key" "$(printf '%s' "$val" | base64 | tr -d '\n')" \
  | kc patch secret "$name" --type merge --patch-file /dev/stdin >/dev/null
log "Secret $NAMESPACE/$name: $key diubah"

# Plain text match on the pod spec; a container or volume named like the Secret also shows up here.
users="$(kc get deploy,sts -o jsonpath='{range .items[*]}{.kind}/{.metadata.name} {.spec.template.spec}{"\n"}{end}' \
  | grep -F "\"name\":\"$name\"" | awk '{print tolower($1)}' || true)"
if [[ -z "$users" ]]; then
  log "tidak ada deployment/statefulset di $NAMESPACE yang memakai $name"
  exit 0
fi
log "dipakai oleh: ${users//$'\n'/ }"
read -r -p "Restart supaya pod memakai nilai baru? [y/N] " ans
[[ "$ans" == [yY] ]] || { log "tidak di-restart; nilai baru berlaku setelah pod restart"; exit 0; }
kc rollout restart $users
