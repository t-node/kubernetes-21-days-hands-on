#!/usr/bin/env bash
# Run the reference answer for every drill and print its output.
#
#   bash solution/check-drills.sh          all of them
#   bash solution/check-drills.sh 8        just task 8
#
# Use it AFTER attempting the drills -- it is both an answer key and a way to
# confirm your own command produces the same thing.
set -uo pipefail
NS=cka32
ONLY=${1:-}

t() {   # t <number> <description> <command...>
  local n=$1; shift
  local d=$1; shift
  [ -n "$ONLY" ] && [ "$ONLY" != "$n" ] && return 0
  echo
  echo "--- $n. $d"
  echo "\$ $*"
  eval "$@" 2>&1 | sed 's/^/    /'
}

kubectl get ns "$NS" >/dev/null 2>&1 || {
  echo "namespace $NS not found -- run: kubectl apply -f solution/setup.yaml"; exit 1; }

t 1 "every node name, one per line" \
  "kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{\"\n\"}{end}'"

t 2 "the first node's name" \
  "kubectl get nodes -o jsonpath='{.items[0].metadata.name}{\"\n\"}'"

t 3 "node name and CPU capacity, tab separated" \
  "kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{\"\t\"}{.status.capacity.cpu}{\"\n\"}{end}'"

t 4 "the same as a table" \
  "kubectl get nodes -o custom-columns=NODE:.metadata.name,CPU:.status.capacity.cpu"

t 5 "kubelet version, OS image, runtime" \
  "kubectl get nodes -o custom-columns=NODE:.metadata.name,KUBELET:.status.nodeInfo.kubeletVersion,OS:.status.nodeInfo.osImage,RUNTIME:.status.nodeInfo.containerRuntimeVersion"

t 6 "pod names in $NS" \
  "kubectl get pods -n $NS -o jsonpath='{range .items[*]}{.metadata.name}{\"\n\"}{end}'"

t 7 "pod name and node, as a table" \
  "kubectl get pods -n $NS -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName"

t 8 "pods on devops-worker, via a JSONPath filter" \
  "kubectl get pods -n $NS -o jsonpath='{range .items[?(@.spec.nodeName==\"devops-worker\")]}{.metadata.name}{\"\n\"}{end}'"

t 9 "pods with tier=frontend -- label selector (preferred)" \
  "kubectl get pods -n $NS -l tier=frontend -o custom-columns=POD:.metadata.name --no-headers"

t 9 "pods with tier=frontend -- JSONPath filter (works, slower to type)" \
  "kubectl get pods -n $NS -o jsonpath='{range .items[?(@.metadata.labels.tier==\"frontend\")]}{.metadata.name}{\"\n\"}{end}'"

t 10 "pods anywhere that are not Running" \
  "kubectl get pods -A --field-selector=status.phase!=Running -o custom-columns=NS:.metadata.namespace,POD:.metadata.name,PHASE:.status.phase"

t 11 "images in the web Deployment's pod template" \
  "kubectl get deploy web -n $NS -o jsonpath='{.spec.template.spec.containers[*].image}{\"\n\"}'"

t 12 "each pod with all its images" \
  "kubectl get pods -n $NS -o custom-columns=POD:.metadata.name,IMAGES:.spec.containers[*].image"

t 13 "container name and CPU request in the web Deployment" \
  "kubectl get deploy web -n $NS -o jsonpath='{range .spec.template.spec.containers[*]}{.name}{\"\t\"}{.resources.requests.cpu}{\"\n\"}{end}'"

t 14 "named ports on the web Deployment's first container" \
  "kubectl get deploy web -n $NS -o jsonpath='{range .spec.template.spec.containers[0].ports[*]}{.name}{\"=\"}{.containerPort}{\"\n\"}{end}'"

t 15 "the web Service's nodePort" \
  "kubectl get svc web -n $NS -o jsonpath='{.spec.ports[0].nodePort}{\"\n\"}'"

t 16 "the example.com/owner annotation (note the escaped dots)" \
  "kubectl get deploy web -n $NS -o jsonpath='{.metadata.annotations.example\.com/owner}{\"\n\"}'"

t 17 "each node's kubernetes.io/hostname label" \
  "kubectl get nodes -o custom-columns=NODE:.metadata.name,HOSTNAME:.metadata.labels.kubernetes\.io/hostname"

t 18 "the decoded password from app-secret" \
  "kubectl get secret app-secret -n $NS -o jsonpath='{.data.password}' | base64 -d; echo"

t 19 "pods sorted by creation time" \
  "kubectl get pods -n $NS --sort-by=.metadata.creationTimestamp"

t 20 "every node and its taints" \
  "kubectl get nodes -o custom-columns=NODE:.metadata.name,TAINTS:.spec.taints[*].key"

t S1 "nodes with a NoSchedule taint" \
  "kubectl get nodes -o jsonpath='{range .items[?(@.spec.taints[*].effect==\"NoSchedule\")]}{.metadata.name}{\"\n\"}{end}'"

t S2 "Deployments with 3 or more replicas -- go-template, because JSONPath cannot compare numbers" \
  "kubectl get deploy -A -o go-template='{{range .items}}{{if ge .spec.replicas 3.0}}{{.metadata.namespace}}/{{.metadata.name}} {{.spec.replicas}}{{\"\n\"}}{{end}}{{end}}'"

t S3 "one row per CONTAINER -- a nested range, with an outer variable" \
  "kubectl get pods -n $NS -o go-template='{{range \$p := .items}}{{range \$p.spec.containers}}{{\$p.metadata.name}}{{\"\t\"}}{{.name}}{{\"\t\"}}{{.image}}{{\"\n\"}}{{end}}{{end}}'"

if [ -z "$ONLY" ] || [ "$ONLY" = "S4" ]; then
  echo
  echo "--- S4. the same as task 4, with NO shell quoting"
  printf 'NODE\tCPU\n.metadata.name\t.status.capacity.cpu\n' > /tmp/cka32-columns.txt
  echo "\$ cat /tmp/cka32-columns.txt"
  sed 's/^/    /' /tmp/cka32-columns.txt
  echo "\$ kubectl get nodes -o custom-columns-file=/tmp/cka32-columns.txt"
  kubectl get nodes -o custom-columns-file=/tmp/cka32-columns.txt 2>&1 | sed 's/^/    /'
  rm -f /tmp/cka32-columns.txt
fi

echo
echo "Done. Compare against your own answers -- several tasks have more than one"
echo "correct command, and the one you can type without thinking is the best one."
