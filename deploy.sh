#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
Usage:
  ./deploy.sh ocr-backend <tag> [--env <env>] [--dry-run] [-- <helm args...>]
  ./deploy.sh rbac-ui <tag> [--env <env>] [--dry-run] [-- <helm args...>]
  ./deploy.sh redis <tag> [--env <env>] [--dry-run] [-- <helm args...>]
  ./deploy.sh application <backend-tag> <rbac-ui-tag> [--env <env>] [--dry-run]
  ./deploy.sh ocr-akta-<service> <tag> [--env <env>] [--dry-run] [-- <helm args...>]
  ./deploy.sh akta <tag> [--env <env>] [--dry-run]

'application' deploys the OCR backend first, then the RBAC UI.
ocr-akta-<service>: orchestrator, extraction, guardrails, structuring, scoring (NILAM OCR akta).
'akta' deploys all five with one tag, the pipeline from its last stage back to the orchestrator, so no stage
hands off to a service that is not there yet.
Redis is deployed separately because it is shared infrastructure.
USAGE
}

if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
  usage
  exit 0
fi

service="$1"
shift

case "$service" in
  ocr-backend)
    exec "$ROOT_DIR/scripts/services/ocr-backend/deploy.sh" "$@"
    ;;
  rbac-ui)
    exec "$ROOT_DIR/scripts/services/rbac-ui/deploy.sh" "$@"
    ;;
  redis)
    exec "$ROOT_DIR/scripts/services/redis/deploy.sh" "$@"
    ;;
  application)
    [[ $# -ge 2 ]] || { usage >&2; exit 2; }
    backend_tag="$1"
    rbac_ui_tag="$2"
    shift 2
    "$ROOT_DIR/scripts/services/ocr-backend/deploy.sh" "$backend_tag" "$@"
    "$ROOT_DIR/scripts/services/rbac-ui/deploy.sh" "$rbac_ui_tag" "$@"
    ;;
  ocr-akta-orchestrator|ocr-akta-extraction|ocr-akta-guardrails|ocr-akta-structuring|ocr-akta-scoring)
    exec "$ROOT_DIR/scripts/services/ocr-akta/deploy.sh" "${service#ocr-akta-}" "$@"
    ;;
  akta)
    [[ $# -ge 1 ]] || { usage >&2; exit 2; }
    for component in scoring structuring guardrails extraction orchestrator; do
      "$ROOT_DIR/scripts/services/ocr-akta/deploy.sh" "$component" "$@"
    done
    ;;
  *)
    printf 'Unknown service: %s\n\n' "$service" >&2
    usage >&2
    exit 2
    ;;
esac
