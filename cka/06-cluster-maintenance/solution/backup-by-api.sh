#!/usr/bin/env bash
# Back up cluster objects by querying the API -- the ONLY option on managed
# Kubernetes (EKS/GKE/AKS), where etcd is not yours to reach.
#
#   bash backup-by-api.sh [outdir]
#
# WHY NOT JUST `kubectl get all -A -o yaml`?
# Because `all` is a small, fixed set: pods, services, deployments, replicasets,
# statefulsets, daemonsets, jobs. It silently omits ConfigMaps, Secrets, PVCs,
# RBAC, Ingresses, CRDs and everything else. This script enumerates every
# namespaced kind the cluster actually knows about.
#
# In production, use Velero -- it does this plus PV snapshots, scheduling and
# selective restore.
set -euo pipefail
OUT="${1:-/tmp/cluster-backup}"
mkdir -p "$OUT"

echo "==> enumerating namespaced, listable resource kinds"
KINDS=$(kubectl api-resources --verbs=list --namespaced -o name 2>/dev/null | sort -u)
echo "$KINDS" | wc -l | xargs echo "    kinds found:"

echo "==> dumping per-kind"
for k in $KINDS; do
  # events are noisy and expire; skip them
  case "$k" in events|events.events.k8s.io) continue ;; esac
  f="${OUT}/${k//\//_}.yaml"
  if kubectl get "$k" --all-namespaces -o yaml > "$f" 2>/dev/null; then
    # drop files that contain no actual items
    if ! grep -q "^  - apiVersion:\|^items:" "$f" 2>/dev/null || [ "$(grep -c 'kind:' "$f")" -le 1 ]; then
      rm -f "$f"
    fi
  else
    rm -f "$f"
  fi
done

echo "==> cluster-scoped extras worth keeping"
for k in namespaces nodes persistentvolumes storageclasses \
         clusterroles clusterrolebindings customresourcedefinitions; do
  kubectl get "$k" -o yaml > "${OUT}/_cluster_${k}.yaml" 2>/dev/null || true
done

echo
echo "==> result"
ls -la "$OUT" | head -25
echo "    files: $(ls -1 "$OUT" | wc -l)   total: $(du -sh "$OUT" | cut -f1)"

cat <<EOF

Compare with the naive approach:

  kubectl get all -A -o yaml | grep -c 'kind: ConfigMap'    # 0
  ls ${OUT} | grep -E 'configmaps|secrets|ingresses'        # present here

CAVEAT: these dumps include status, resourceVersion, uid and other live fields.
Re-applying them verbatim will produce warnings and some will be rejected. For
real restores use Velero, which strips them properly. For git, commit your
hand-written manifests, not these.
EOF
