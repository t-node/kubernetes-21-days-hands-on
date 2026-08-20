#!/usr/bin/env bash
# Map the cluster's DNS installation, from the API side.
#
#   bash solution/dns-map.sh
set -uo pipefail
say() { echo; echo "=== $*"; }

say "1. the four objects (24.2)"
kubectl -n kube-system get deployment coredns 2>/dev/null
kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide 2>/dev/null
kubectl -n kube-system get svc kube-dns 2>/dev/null
kubectl -n kube-system get configmap coredns 2>/dev/null
echo
echo "NOTE the naming: the Deployment is 'coredns', the Service and label are"
echo "     still 'kube-dns' -- a compatibility artefact from the 1.12 switch."

say "2. do the endpoints exist? (the second command for any DNS complaint)"
kubectl -n kube-system get endpoints kube-dns 2>/dev/null
kubectl -n kube-system get endpointslices -l kubernetes.io/service-name=kube-dns 2>/dev/null

say "3. the Corefile (24.3)"
kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' 2>/dev/null

say "4. the plugins that are enabled"
kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' 2>/dev/null \
  | sed -n 's/^ *\([a-z]*\).*/\1/p' | grep -vE '^$|^\.|}' | sort -u | tr '\n' ' '
echo

say "5. the cluster domain and the pods setting"
kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' 2>/dev/null \
  | grep -E "kubernetes|pods|ttl|fallthrough" | sed 's/^/   /'

say "6. where queries CoreDNS cannot answer are sent"
kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' 2>/dev/null \
  | grep -A2 forward | sed 's/^/   /'
echo
echo "   'forward . /etc/resolv.conf' means the NODE's resolver. On this node:"
docker exec "${NODE:-devops-control-plane}" cat /etc/resolv.conf 2>/dev/null | sed 's/^/      /'

say "7. what the kubelet stamps into every pod (24.4)"
docker exec "${NODE:-devops-control-plane}" grep -A3 -E "clusterDNS|clusterDomain" \
  /var/lib/kubelet/config.yaml 2>/dev/null | sed 's/^/   /'

say "8. the CoreDNS Service ClusterIP must match clusterDNS above"
kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}{"\n"}' 2>/dev/null

say "9. recent CoreDNS logs (look for 'Loop ... detected', 24.3)"
kubectl -n kube-system logs -l k8s-app=kube-dns --tail=15 2>/dev/null | sed 's/^/   /'
