#!/usr/bin/env bash
# Jalankan perintah apa pun (kubectl, helm, bash) ke cluster sebuah environment, lewat tunnel bastion bila
# cluster-nya private. KUBECONFIG sementara, ~/.kube/config tidak disentuh.
#
# Usage:
#   ./scripts/kube.sh [--env dev] -- <perintah...>
#
# Contoh:
#   ./scripts/kube.sh --env shared -- kubectl get pods -n bribrain-ocr-nilam
#   ./scripts/kube.sh --env shared -- kubectl logs -n bribrain-ocr-nilam deploy/ms-bribrain-nilam-ocr-orchestrator-worker -f
#   ./scripts/kube.sh --env shared -- bash      # shell interaktif, tunnel terbuka sampai exit
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

DEPLOY_ENV="${DEPLOY_ENV:-dev}"
case "${1:-}" in -e|--env) [[ $# -ge 2 ]] || die "--env butuh nilai"; DEPLOY_ENV="$2"; shift 2 ;; esac
[[ "${1:-}" == "--" ]] && shift
[[ $# -gt 0 ]] || { usage; exit 1; }

load_env
need_tools gcloud kubectl
gke_connect
"$@"
