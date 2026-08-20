#!/usr/bin/env bash
# Restore a pg_dump produced by backup.sh.
#
#   ./restore.sh backups/devboard-20260820T120000Z.sql
#
# The dump is taken with --clean --if-exists, so it drops and recreates objects.
# THAT MEANS IT IS DESTRUCTIVE: current data is replaced.
set -euo pipefail
NS=devboard
POD=postgres-0

FILE="${1:?usage: ./restore.sh <dump.sql>}"
[ -f "${FILE}" ] || { echo "no such file: ${FILE}" >&2; exit 1; }

echo "This REPLACES the current contents of ${NS}/${POD} devboard database."
printf "Type 'restore' to continue: "
read -r CONFIRM
[ "${CONFIRM}" = "restore" ] || { echo "aborted"; exit 1; }

BEFORE=$(kubectl exec -n "${NS}" "${POD}" -- \
  psql -U devboard -d devboard -tAc "SELECT count(*) FROM tasks;" 2>/dev/null | tr -d '\r' || echo "?")

echo "==> restoring ${FILE}"
kubectl exec -i -n "${NS}" "${POD}" -- \
  psql -U devboard -d devboard --quiet --set ON_ERROR_STOP=off < "${FILE}" >/dev/null

AFTER=$(kubectl exec -n "${NS}" "${POD}" -- \
  psql -U devboard -d devboard -tAc "SELECT count(*) FROM tasks;" | tr -d '\r')

echo
echo "tasks before: ${BEFORE}"
echo "tasks after:  ${AFTER}"
echo "Restore complete."
