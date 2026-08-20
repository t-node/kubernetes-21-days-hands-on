#!/usr/bin/env bash
# Grade the mock exam by checking the END STATE of every task -- the same way
# the real exam does.
#
#   bash solution/grade.sh
#
# It never says HOW to fix anything; see solution/README.md for that.
set -uo pipefail
CP=${CP:-devops-control-plane}
A=0; W=0; N=0; ST=0; T=0
AMAX=25; WMAX=15; NMAX=20; STMAX=10; TMAX=30

pt() {  # pt <domain-var> <points> <task> <description> <0|1>
  local dom=$1 pts=$2 task=$3 desc=$4 okflag=$5
  if [ "$okflag" = "1" ]; then
    printf "  [%d/%d]  Task %-3s %s\n" "$pts" "$pts" "$task" "$desc"
    eval "$dom=\$(( \$$dom + $pts ))"
  else
    printf "  [0/%d]  Task %-3s %s\n" "$pts" "$task" "$desc"
  fi
}

echo "== Cluster Architecture, Installation & Configuration =="

r=0
if kubectl get sa pipeline -n mock-a >/dev/null 2>&1; then
  a1=$(kubectl auth can-i list pods --as=system:serviceaccount:mock-a:pipeline -n mock-a 2>/dev/null)
  a2=$(kubectl auth can-i get pods/log --as=system:serviceaccount:mock-a:pipeline -n mock-a 2>/dev/null)
  a3=$(kubectl auth can-i delete pods --as=system:serviceaccount:mock-a:pipeline -n mock-a 2>/dev/null)
  a4=$(kubectl auth can-i list secrets --as=system:serviceaccount:mock-a:pipeline -n mock-a 2>/dev/null)
  [ "$a1" = "yes" ] && [ "$a2" = "yes" ] && [ "$a3" = "no" ] && [ "$a4" = "no" ] && r=1
fi
pt A 4 1 "ServiceAccount can read pods and logs, nothing else" "$r"

r=0
b1=$(kubectl auth can-i list deployments --as=auditor -n mock-a 2>/dev/null)
b2=$(kubectl auth can-i get configmaps  --as=auditor -n mock-a 2>/dev/null)
b3=$(kubectl auth can-i create pods     --as=auditor -n mock-a 2>/dev/null)
b4=$(kubectl auth can-i delete pods     --as=auditor -n mock-a 2>/dev/null)
[ "$b1" = "yes" ] && [ "$b2" = "yes" ] && [ "$b3" = "no" ] && [ "$b4" = "no" ] && r=1
pt A 4 2 "auditor can read everything and write nothing" "$r"

r=0
docker exec "$CP" test -s /opt/etcd-backup.db 2>/dev/null && r=1
pt A 5 3 "an etcd snapshot exists at /opt/etcd-backup.db" "$r"

r=0
if docker exec "$CP" test -s /opt/cert-expiry.txt 2>/dev/null; then
  docker exec "$CP" grep -qi apiserver /opt/cert-expiry.txt 2>/dev/null \
    && docker exec "$CP" grep -qi "^ca" /opt/cert-expiry.txt 2>/dev/null && r=1
fi
pt A 4 4 "/opt/cert-expiry.txt records both expiry dates" "$r"

r=0
if kubectl get sc mock-retain >/dev/null 2>&1; then
  rec=$(kubectl get sc mock-retain -o jsonpath='{.reclaimPolicy}')
  exp=$(kubectl get sc mock-retain -o jsonpath='{.allowVolumeExpansion}')
  prv=$(kubectl get sc mock-retain -o jsonpath='{.provisioner}')
  [ "$rec" = "Retain" ] && [ "$exp" = "true" ] && [ -n "$prv" ] && r=1
fi
pt A 4 5 "StorageClass mock-retain: Retain and expandable" "$r"

r=0
if docker exec devops-worker test -f /etc/kubernetes/manifests/mock-static.yaml 2>/dev/null; then
  kubectl get pods -A 2>/dev/null | grep -q "mock-static-devops-worker" && r=1
fi
pt A 4 6 "a static pod named mock-static runs on devops-worker" "$r"

echo
echo "== Workloads & Scheduling =="

r=0
if kubectl get deploy frontend -n mock-w >/dev/null 2>&1; then
  rep=$(kubectl get deploy frontend -n mock-w -o jsonpath='{.status.readyReplicas}')
  cpu=$(kubectl get deploy frontend -n mock-w -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}')
  mem=$(kubectl get deploy frontend -n mock-w -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}')
  pn=$(kubectl get deploy frontend -n mock-w -o jsonpath='{.spec.template.spec.containers[0].ports[0].name}')
  [ "${rep:-0}" -ge 3 ] 2>/dev/null && [ "$cpu" = "50m" ] && [ "$mem" = "128Mi" ] && [ "$pn" = "http" ] && r=1
fi
pt W 3 7 "Deployment frontend: ready, 50m cpu, 128Mi limit, named port" "$r"

r=0
if kubectl get pod multi -n mock-w >/dev/null 2>&1; then
  c=$(kubectl get pod multi -n mock-w -o jsonpath='{.spec.containers[*].name}')
  v=$(kubectl get pod multi -n mock-w -o jsonpath='{.spec.volumes[0].emptyDir}')
  m=$(kubectl get pod multi -n mock-w -o jsonpath='{.spec.containers[*].volumeMounts[?(@.mountPath=="/shared")].mountPath}' | wc -w)
  ph=$(kubectl get pod multi -n mock-w -o jsonpath='{.status.phase}')
  echo "$c" | grep -q main && echo "$c" | grep -q sidecar && [ -n "$v" ] \
    && [ "${m:-0}" -eq 2 ] && [ "$ph" = "Running" ] && r=1
fi
pt W 3 8 "pod multi: two containers sharing an emptyDir at /shared" "$r"

r=0
if kubectl get cronjob reporter -n mock-w >/dev/null 2>&1; then
  s=$(kubectl get cronjob reporter -n mock-w -o jsonpath='{.spec.schedule}')
  sh=$(kubectl get cronjob reporter -n mock-w -o jsonpath='{.spec.successfulJobsHistoryLimit}')
  fh=$(kubectl get cronjob reporter -n mock-w -o jsonpath='{.spec.failedJobsHistoryLimit}')
  [ "$s" = "*/5 * * * *" ] && [ "$sh" = "2" ] && [ "$fh" = "1" ] && r=1
fi
pt W 3 9 "CronJob reporter: every 5 minutes, history 2/1" "$r"

r=0
lbl=$(kubectl get node devops-worker2 -o jsonpath='{.metadata.labels.tier}' 2>/dev/null)
if [ "$lbl" = "gold" ] && kubectl get pod picky -n mock-w >/dev/null 2>&1; then
  node=$(kubectl get pod picky -n mock-w -o jsonpath='{.spec.nodeName}')
  sel=$(kubectl get pod picky -n mock-w -o jsonpath='{.spec.nodeSelector}{.spec.affinity}')
  [ "$node" = "devops-worker2" ] && [ -n "$sel" ] && r=1
fi
pt W 3 10 "node labelled tier=gold and pod picky pinned to it" "$r"

r=0
if kubectl get deploy frontend -n mock-w >/dev/null 2>&1; then
  rep=$(kubectl get deploy frontend -n mock-w -o jsonpath='{.spec.replicas}')
  ann=$(kubectl get deploy frontend -n mock-w -o jsonpath='{.metadata.annotations.kubernetes\.io/change-cause}')
  [ "$rep" = "5" ] && [ -n "$ann" ] && r=1
fi
pt W 3 11 "frontend scaled to 5 with a recorded change-cause" "$r"

echo
echo "== Services & Networking =="

r=0
if kubectl get svc web-svc -n mock-n >/dev/null 2>&1; then
  tp=$(kubectl get svc web-svc -n mock-n -o jsonpath='{.spec.ports[0].targetPort}')
  p=$(kubectl get svc web-svc -n mock-n -o jsonpath='{.spec.ports[0].port}')
  ep=$(kubectl get endpoints web-svc -n mock-n -o jsonpath='{.subsets[0].addresses}' 2>/dev/null | grep -c '"ip"')
  [ "$tp" = "http" ] && [ "$p" = "80" ] && [ "${ep:-0}" -ge 1 ] 2>/dev/null && r=1
fi
pt N 4 12 "Service web-svc on 80 -> named port http, with endpoints" "$r"

r=0
if kubectl get svc web-np -n mock-n >/dev/null 2>&1; then
  np=$(kubectl get svc web-np -n mock-n -o jsonpath='{.spec.ports[0].nodePort}')
  et=$(kubectl get svc web-np -n mock-n -o jsonpath='{.spec.externalTrafficPolicy}')
  [ "$np" = "30333" ] && [ "$et" = "Local" ] && r=1
fi
pt N 4 13 "NodePort web-np on 30333 with externalTrafficPolicy: Local" "$r"

r=0
if kubectl get svc web-hl -n mock-n >/dev/null 2>&1; then
  cip=$(kubectl get svc web-hl -n mock-n -o jsonpath='{.spec.clusterIP}')
  [ "$cip" = "None" ] && r=1
fi
pt N 4 14 "headless Service web-hl exists with clusterIP: None" "$r"

r=0
if kubectl get netpol deny-all-ingress -n mock-n >/dev/null 2>&1; then
  sel=$(kubectl get netpol deny-all-ingress -n mock-n -o jsonpath='{.spec.podSelector}')
  types=$(kubectl get netpol deny-all-ingress -n mock-n -o jsonpath='{.spec.policyTypes[*]}')
  rules=$(kubectl get netpol deny-all-ingress -n mock-n -o jsonpath='{.spec.ingress}')
  [ "$sel" = "{}" ] && echo "$types" | grep -q Ingress && [ -z "$rules" ] && r=1
fi
pt N 4 15 "NetworkPolicy denies all ingress in mock-n" "$r"

r=0
if [ -s /tmp/mock-dns.txt ]; then
  cip=$(kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}')
  head -1 /tmp/mock-dns.txt | grep -q "$cip" && [ "$(grep -c . /tmp/mock-dns.txt)" -ge 2 ] && r=1
fi
pt N 4 16 "/tmp/mock-dns.txt lists the ClusterIP then the CoreDNS pods" "$r"

echo
echo "== Storage =="

r=0
if kubectl get pvc data -n mock-s >/dev/null 2>&1; then
  ph=$(kubectl get pvc data -n mock-s -o jsonpath='{.status.phase}')
  sz=$(kubectl get pvc data -n mock-s -o jsonpath='{.spec.resources.requests.storage}')
  if [ "$ph" = "Bound" ] && [ "$sz" = "200Mi" ]; then
    out=$(kubectl exec -n mock-s writer -- cat /data/proof.txt 2>/dev/null | tr -d '\r\n')
    [ "$out" = "mock-exam-ok" ] && r=1
  fi
fi
pt ST 10 17 "PVC data Bound at 200Mi and /data/proof.txt readable" "$r"

echo
echo "== Troubleshooting =="

r=0
code=$(kubectl exec -n mock-t1 client -- curl -s -m5 -o /dev/null -w "%{http_code}" http://web 2>/dev/null)
[ "$code" = "200" ] && r=1
pt T 6 18 "mock-t1: curl http://web returns 200 from the client pod" "$r"

r=0
rr=$(kubectl get deploy api -n mock-t2 -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[ "${rr:-0}" -eq 2 ] 2>/dev/null && r=1
pt T 6 19 "mock-t2: the api Deployment has 2 ready replicas" "$r"

r=0
ready=$(kubectl get pod cache -n mock-t3 -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)
ph=$(kubectl get pod cache -n mock-t3 -o jsonpath='{.status.phase}' 2>/dev/null)
[ "$ready" = "true" ] && [ "$ph" = "Running" ] && r=1
pt T 6 20 "mock-t3: the cache pod is Running and 1/1" "$r"

r=0
rr=$(kubectl get deploy worker -n mock-t4 -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
tol=$(kubectl get deploy worker -n mock-t4 -o jsonpath='{.spec.template.spec.tolerations[0].value}' 2>/dev/null)
aff=$(kubectl get deploy worker -n mock-t4 -o jsonpath='{.spec.template.spec.affinity.nodeAffinity}' 2>/dev/null)
if [ "${rr:-0}" -eq 3 ] 2>/dev/null; then
  if [ "$tol" = "batch" ] && [ -n "$aff" ]; then
    r=1
  else
    echo "         (3 replicas ready, but the workload's tolerations/affinity were changed)"
  fi
fi
pt T 6 21 "mock-t4: 3 replicas Running, workload spec unchanged" "$r"

r=0
c1=$(kubectl auth can-i list pods --as=system:serviceaccount:mock-t5:reader -n mock-t5 2>/dev/null)
c2=$(kubectl auth can-i delete pods --as=system:serviceaccount:mock-t5:reader -n mock-t5 2>/dev/null)
[ "$c1" = "yes" ] && [ "$c2" = "no" ] && r=1
pt T 3 22 "mock-t5: reader can list pods and nothing more" "$r"

r=0
if [ -f /tmp/mock-unschedulable.txt ]; then
  want=$(kubectl get nodes -o jsonpath='{range .items[?(@.spec.unschedulable==true)]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -c .)
  got=$(grep -c . /tmp/mock-unschedulable.txt 2>/dev/null)
  [ "${want:-0}" = "${got:-0}" ] && r=1
fi
pt T 3 23 "/tmp/mock-unschedulable.txt matches the cluster" "$r"

TOTAL=$(( A + W + N + ST + T ))
echo
echo "== SCORE =="
printf "  %-34s %3d / %d\n" "Cluster Architecture" "$A" "$AMAX"
printf "  %-34s %3d / %d\n" "Workloads & Scheduling" "$W" "$WMAX"
printf "  %-34s %3d / %d\n" "Services & Networking" "$N" "$NMAX"
printf "  %-34s %3d / %d\n" "Storage" "$ST" "$STMAX"
printf "  %-34s %3d / %d\n" "Troubleshooting" "$T" "$TMAX"
echo "  ----------------------------------------------"
if [ "$TOTAL" -ge 66 ]; then
  printf "  %-34s %3d / 100     PASS\n" "TOTAL" "$TOTAL"
else
  printf "  %-34s %3d / 100     FAIL (66 required)\n" "TOTAL" "$TOTAL"
fi
echo
echo "Read the per-domain lines, not the total. Troubleshooting is 30% of the"
echo "real exam and its tasks are less friendly than these."
