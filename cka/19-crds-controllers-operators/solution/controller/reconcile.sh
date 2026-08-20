#!/usr/bin/env sh
# A custom controller, in POSIX shell and kubectl.
#
# It does exactly what any controller does (19.5):
#
#   observe  -- list every FlightTicket in the cluster
#   diff     -- which ones have no booking confirmation yet?
#   act      -- "book" them, and create a child object recording the booking
#   report   -- write the result into .status via the status subresource
#
# What it deliberately does NOT do: informers, a workqueue, rate limiting,
# leader election. A real Go controller has all four. This has a `sleep`.
set -u

GROUP="flights.example.com"
KIND="flighttickets.${GROUP}"
INTERVAL="${INTERVAL:-5}"

log() { echo "$(date -u +%H:%M:%S) $*"; }

log "flight-ticket controller starting; polling every ${INTERVAL}s"

while true; do
  # ---------------------------------------------------------------- observe
  # custom-columns rather than jq: the kubectl image ships no jq, and an
  # absent field renders as <none>, which is exactly the signal we need.
  kubectl get "$KIND" --all-namespaces --no-headers -o custom-columns=\
'NS:.metadata.namespace,NAME:.metadata.name,FROM:.spec.from,TO:.spec.to,NUM:.spec.number,CLASS:.spec.class,CONF:.status.confirmation,UID:.metadata.uid' \
    2>/dev/null | while read -r NS NAME FROM TO NUM CLASS CONF UID; do

    [ -z "${NAME:-}" ] && continue

    # ------------------------------------------------------------- diff
    if [ "$CONF" != "<none>" ] && [ -n "$CONF" ]; then
      continue                      # already booked -- nothing to do
    fi

    # ------------------------------------------------------------- act
    # Stand-in for "call the airline's booking API". Derive a stable code from
    # the object's UID so reconciling twice produces the same answer -- real
    # controllers must be idempotent for the same reason.
    CODE="BK-$(echo "$UID" | tr -d '-' | cut -c1-6 | tr 'a-z' 'A-Z')"
    log "booking ${NS}/${NAME}: ${FROM} -> ${TO} x${NUM} (${CLASS}) => ${CODE}"

    # The child object. ownerReferences is what makes Kubernetes delete this
    # automatically when the ticket goes away (19.6) -- no code required.
    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: ConfigMap
metadata:
  name: booking-${NAME}
  namespace: ${NS}
  labels:
    flights.example.com/ticket: ${NAME}
  ownerReferences:
    - apiVersion: ${GROUP}/v1
      kind: FlightTicket
      name: ${NAME}
      uid: ${UID}
      blockOwnerDeletion: false
data:
  confirmation: "${CODE}"
  route: "${FROM}-${TO}"
  seats: "${NUM}"
  class: "${CLASS}"
EOF

    # ------------------------------------------------------------ report
    # --subresource=status is the only way to write status once the status
    # subresource is enabled. Writing it in a normal apply is silently dropped.
    kubectl patch "$KIND" "$NAME" -n "$NS" --subresource=status --type=merge \
      -p "{\"status\":{\"state\":\"Booked\",\"confirmation\":\"${CODE}\"}}" >/dev/null \
      && log "  status written for ${NS}/${NAME}" \
      || log "  FAILED to write status for ${NS}/${NAME}"
  done

  sleep "$INTERVAL"
done
