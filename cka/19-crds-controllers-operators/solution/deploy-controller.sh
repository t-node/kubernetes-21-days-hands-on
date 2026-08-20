#!/usr/bin/env bash
# Deploy the flight-ticket controller.
#
#   bash solution/deploy-controller.sh
#
# It loads controller/reconcile.sh into the ConfigMap the Deployment mounts,
# then applies the RBAC and the Deployment. Re-run it after editing the script;
# it restarts the Deployment so the new code is picked up.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
NS=${NS:-cka19}

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "==> loading controller/reconcile.sh into a ConfigMap"
kubectl create configmap flight-controller-code -n "$NS" \
  --from-file=reconcile.sh="${HERE}/controller/reconcile.sh" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "==> applying ServiceAccount, RBAC and Deployment"
kubectl apply -f "${HERE}/05-controller.yaml" >/dev/null

# The ConfigMap above is applied twice -- once with the real code, once with the
# placeholder inside 05-controller.yaml. Re-apply the real one last.
kubectl create configmap flight-controller-code -n "$NS" \
  --from-file=reconcile.sh="${HERE}/controller/reconcile.sh" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl rollout restart deployment/flight-controller -n "$NS" >/dev/null
kubectl rollout status deployment/flight-controller -n "$NS" --timeout=180s

echo
echo "controller running. Watch it work:"
echo "   kubectl logs -n ${NS} -l app=flight-controller -f"
