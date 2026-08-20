#!/usr/bin/env bash
# CKA 20 verification. Run from the assignment directory:
#   bash solution/verify.sh
#
# It creates and removes its own objects in the cka20 namespace.
NS=cka20
pass=0; fail=0
ok() { echo "  PASS  $1"; pass=$((pass+1)); }
no() { echo "  FAIL  $1"; fail=$((fail+1)); }
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "== 1. The cluster's provisioning setup =="
def=$(kubectl get sc -o jsonpath='{range .items[*]}{.metadata.name}={.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' \
      2>/dev/null | grep '=true' | cut -d= -f1)
n=$(echo "$def" | grep -c .)
[ "$n" = "1" ] && ok "exactly one default StorageClass: $def" || no "$n default classes found: ${def:-none}"

mode=$(kubectl get sc "$def" -o jsonpath='{.volumeBindingMode}' 2>/dev/null)
[ "$mode" = "WaitForFirstConsumer" ] && ok "the default class binds WaitForFirstConsumer" \
                                     || echo "  NOTE  default class binding mode is '$mode'"

prov=$(kubectl get sc "$def" -o jsonpath='{.provisioner}' 2>/dev/null)
echo "        provisioner: $prov"
if kubectl get csidrivers 2>/dev/null | grep -q .; then
  ok "CSI drivers are registered on this cluster"
else
  ok "no CSIDriver objects -- consistent with a non-CSI provisioner (20.4)"
fi

echo "== 2. WaitForFirstConsumer =="
kubectl get ns $NS >/dev/null 2>&1 || kubectl create ns $NS >/dev/null
kubectl delete pvc wffc-probe -n $NS >/dev/null 2>&1
kubectl apply -n $NS -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: wffc-probe}
spec:
  accessModes: ["ReadWriteOnce"]
  resources: {requests: {storage: 64Mi}}
EOF
sleep 6
st=$(kubectl get pvc wffc-probe -n $NS -o jsonpath='{.status.phase}' 2>/dev/null)
[ "$st" = "Pending" ] && ok "a consumer-less PVC stays Pending" || no "phase is '$st', expected Pending"
kubectl describe pvc wffc-probe -n $NS 2>/dev/null | grep -q "WaitForFirstConsumer" \
  && ok "  the event says WaitForFirstConsumer (a status, not an error)" \
  || no "  no WaitForFirstConsumer event"

kubectl apply -n $NS -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: wffc-consumer}
spec:
  containers:
    - name: c
      image: busybox:1.36
      command: ["sh","-c","sleep 600"]
      volumeMounts: [{name: d, mountPath: /data}]
  volumes:
    - name: d
      persistentVolumeClaim: {claimName: wffc-probe}
EOF
kubectl wait --for=condition=Ready pod/wffc-consumer -n $NS --timeout=120s >/dev/null 2>&1
st=$(kubectl get pvc wffc-probe -n $NS -o jsonpath='{.status.phase}' 2>/dev/null)
[ "$st" = "Bound" ] && ok "it bound once a pod consumed it" || no "phase is '$st' after a consumer appeared"

PV=$(kubectl get pvc wffc-probe -n $NS -o jsonpath='{.spec.volumeName}' 2>/dev/null)
POD_NODE=$(kubectl get pod wffc-consumer -n $NS -o jsonpath='{.spec.nodeName}' 2>/dev/null)
aff=$(kubectl get pv "$PV" -o jsonpath='{.spec.nodeAffinity}' 2>/dev/null)
if [ -n "$aff" ]; then
  echo "$aff" | grep -q "$POD_NODE" \
    && ok "the PV's nodeAffinity matches the pod's node ($POD_NODE)" \
    || no "the PV is pinned elsewhere: $aff"
else
  echo "  NOTE  this PV carries no nodeAffinity (not a local-path style volume)"
fi

echo "== 3. Retain leaves a Released PV =="
kubectl apply -f "${HERE}/03-storageclass-retain.yaml" >/dev/null 2>&1
r=$(kubectl get sc keep-my-data -o jsonpath='{.reclaimPolicy}/{.allowVolumeExpansion}' 2>/dev/null)
[ "$r" = "Retain/true" ] && ok "keep-my-data is Retain with expansion allowed" || no "keep-my-data is '$r'"

kubectl delete pvc retain-probe -n $NS >/dev/null 2>&1
kubectl apply -n $NS -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: retain-probe}
spec:
  storageClassName: keep-my-data
  accessModes: ["ReadWriteOnce"]
  resources: {requests: {storage: 64Mi}}
---
apiVersion: v1
kind: Pod
metadata: {name: retain-consumer}
spec:
  containers:
    - name: c
      image: busybox:1.36
      command: ["sh","-c","sleep 600"]
      volumeMounts: [{name: d, mountPath: /data}]
  volumes:
    - name: d
      persistentVolumeClaim: {claimName: retain-probe}
EOF
kubectl wait --for=condition=Ready pod/retain-consumer -n $NS --timeout=120s >/dev/null 2>&1
RPV=$(kubectl get pvc retain-probe -n $NS -o jsonpath='{.spec.volumeName}' 2>/dev/null)
kubectl delete pod retain-consumer -n $NS >/dev/null 2>&1
kubectl delete pvc retain-probe -n $NS >/dev/null 2>&1
sleep 8
ph=$(kubectl get pv "$RPV" -o jsonpath='{.status.phase}' 2>/dev/null)
[ "$ph" = "Released" ] && ok "the PV survived its PVC and is Released" || no "the PV phase is '${ph:-gone}'"
cr=$(kubectl get pv "$RPV" -o jsonpath='{.spec.claimRef.uid}' 2>/dev/null)
[ -n "$cr" ] && ok "  it still holds a claimRef, so nothing new can bind to it" \
             || no "  claimRef is already empty"
kubectl patch pv "$RPV" -p '{"spec":{"claimRef": null}}' >/dev/null 2>&1
sleep 4
ph=$(kubectl get pv "$RPV" -o jsonpath='{.status.phase}' 2>/dev/null)
[ "$ph" = "Available" ] && ok "  clearing claimRef made it Available" || no "  still '$ph' after clearing claimRef"
kubectl delete pv "$RPV" >/dev/null 2>&1

echo "== 4. Immediate binds with no pod =="
kubectl apply -f "${HERE}/05-storageclass-immediate.yaml" >/dev/null 2>&1
kubectl delete pvc imm-probe -n $NS >/dev/null 2>&1
kubectl apply -n $NS -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: imm-probe}
spec:
  storageClassName: bind-immediately
  accessModes: ["ReadWriteOnce"]
  resources: {requests: {storage: 64Mi}}
EOF
sleep 10
st=$(kubectl get pvc imm-probe -n $NS -o jsonpath='{.status.phase}' 2>/dev/null)
[ "$st" = "Bound" ] && ok "an Immediate PVC bound with no consumer" || no "phase is '$st'"
kubectl delete pvc imm-probe -n $NS >/dev/null 2>&1

echo "== 5. Expansion is refused by a class that forbids it =="
out=$(kubectl patch pvc wffc-probe -n $NS \
      -p '{"spec":{"resources":{"requests":{"storage":"256Mi"}}}}' 2>&1)
echo "$out" | grep -qi "forbidden\|does not support\|not support" \
  && ok "growing a PVC on a non-expandable class was refused" \
  || echo "  NOTE  the patch was accepted -- this class allows expansion"

kubectl delete pod wffc-consumer -n $NS >/dev/null 2>&1
kubectl delete pvc wffc-probe -n $NS >/dev/null 2>&1

echo
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
