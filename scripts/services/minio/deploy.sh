#!/usr/bin/env bash
# Deploy MinIO (object storage untuk service OCR per dokumen) dari Nexus ke GKE.
#
# Usage:
#   ./deploy.sh minio <tag> [--env shared] [--dry-run] [-- <argumen helm tambahan>]
#
# Contoh:
#   ./deploy.sh minio RELEASE.2025-04-22T22-12-26Z --env shared
#   ./deploy.sh minio RELEASE.2025-04-22T22-12-26Z --env shared --dry-run
source "$(dirname "${BASH_SOURCE[0]}")/../../_lib.sh"

parse_args "$@"
load_env
require MINIO_RELEASE MINIO_NAMESPACE MINIO_IMAGE MINIO_SECRET

NAMESPACE="$MINIO_NAMESPACE"
APP_SECRET="$MINIO_SECRET"
deploy_component "$MINIO_RELEASE" minio "$MINIO_IMAGE" --set "existingSecret=$MINIO_SECRET"
