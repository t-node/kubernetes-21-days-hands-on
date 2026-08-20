#!/usr/bin/env bash
# Logical backup of the DevBoard database.
#
#   ./backup.sh                      -> backups/devboard-<utc-timestamp>.sql
#   ./backup.sh /path/to/file.sql
#
# THIS IS THE SIMPLE TIER, and it is honest about its limits: pg_dump is fine
# for small databases and gives you a portable, human-readable artefact. It does
# NOT give point-in-time recovery, and it takes a consistent snapshot only of
# the moment it runs.
#
# For anything real: continuous WAL archiving with pgBackRest or WAL-G to object
# storage, driven by a CronJob, which gives PITR. Or use a managed database and
# let it do this.
#
# AN UNTESTED BACKUP IS NOT A BACKUP. restore.sh exists so you can test it.
set -euo pipefail
NS=devboard
POD=postgres-0
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STAMP="$(kubectl exec -n "${NS}" "${POD}" -- date -u +%Y%m%dT%H%M%SZ | tr -d '\r')"
OUT="${1:-${HERE}/backups/devboard-${STAMP}.sql}"
mkdir -p "$(dirname "${OUT}")"

echo "==> dumping ${NS}/${POD} -> ${OUT}"
kubectl exec -n "${NS}" "${POD}" -- \
  pg_dump -U devboard -d devboard --clean --if-exists > "${OUT}"

SIZE=$(wc -c < "${OUT}")
if [ "${SIZE}" -lt 100 ]; then
  echo "ERROR: dump is only ${SIZE} bytes -- something went wrong" >&2
  exit 1
fi

echo "Wrote ${OUT} (${SIZE} bytes)"
echo
echo "Verify the restore path now, not during an incident:"
echo "  ./restore.sh ${OUT}"
