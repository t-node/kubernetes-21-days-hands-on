#!/usr/bin/env bash
# Fetch the DevBoard application source into app/devboard/.
#
# The course deploys a REAL application, not a toy: t-node/devboard is a
# React + Vite frontend, a Go + Gin API, and Postgres 16.
#
#   ./get-devboard.sh            # clone (or update) the app source
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="https://github.com/t-node/devboard.git"
DEST="${HERE}/devboard"

if [ -d "${DEST}/.git" ]; then
  echo "==> updating existing checkout in app/devboard"
  git -C "${DEST}" pull --ff-only
else
  echo "==> cloning ${REPO} into app/devboard"
  git clone --depth 1 "${REPO}" "${DEST}"
fi

echo
echo "Source ready. Files that matter for this course:"
echo "  app/devboard/backend/main.go              the Go API"
echo "  app/devboard/frontend/vite.preview.config.js   the /api proxy target"
echo "  app/devboard/init/postgres/01_schema.sql  the schema"
echo "  app/devboard/init/postgres/02_seed.sql    the seed data"
echo "  app/devboard/docker-compose.yml           the shape you are about to port to k8s"
