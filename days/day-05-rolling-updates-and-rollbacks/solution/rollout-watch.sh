#!/usr/bin/env bash
# Make a rolling update VISIBLE.
#
# Polls the app continuously and prints which VERSION answered each request, so
# you can watch traffic shift from old to new -- and, with the Recreate
# strategy, watch it fail outright.
#
#   Terminal 1:  bash rollout-watch.sh
#   Terminal 2:  kubectl set image deployment/frontend frontend=devboard-frontend:2.0 -n devboard
#
# Output is one character per request:
#   1 = served by v1.0      2 = served by v2.0      . = 200 but version unknown
#   X = FAILED (non-200)  <- with RollingUpdate you should see none of these
set -uo pipefail
NS="${NS:-devboard}"
URL="${URL:-http://localhost:30080}"
INTERVAL="${INTERVAL:-0.3}"

printf 'polling %s every %ss -- Ctrl-C to stop\n' "$URL" "$INTERVAL"
printf '1=v1.0  2=v2.0  .=200(unknown)  X=FAILED\n\n'

ok=0; fail=0
trap 'printf "\n\n%d ok, %d failed\n" "$ok" "$fail"; exit 0' INT

while true; do
  body=$(curl -s --max-time 2 "$URL" 2>/dev/null)
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$URL" 2>/dev/null)
  if [ "$code" != "200" ]; then
    printf 'X'; fail=$((fail+1))
  else
    ok=$((ok+1))
    case "$body" in
      *v2.0*) printf '2' ;;
      *v1.0*) printf '1' ;;
      *)      printf '.' ;;
    esac
  fi
  sleep "$INTERVAL"
done
