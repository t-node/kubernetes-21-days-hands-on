#!/usr/bin/env bash
# CKA 32 verification. Run from the assignment directory:
#   bash solution/verify.sh
NS=cka32
pass=0; fail=0
ok() { echo "  PASS  $1"; pass=$((pass+1)); }
no() { echo "  FAIL  $1"; fail=$((fail+1)); }

echo "== 0. Setup =="
kubectl get ns $NS >/dev/null 2>&1 && ok "namespace $NS exists" || {
  no "apply solution/setup.yaml first"; echo; echo "== $pass passed, 1 failed =="; exit 1; }
n=$(kubectl get pods -n $NS --no-headers 2>/dev/null | wc -l)
[ "${n:-0}" -ge 5 ] 2>/dev/null && ok "$n pods to query" || no "only ${n:-0} pods -- has the rollout finished?"

echo "== 1. A range produces one line per item (32.4) =="
out=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
lines=$(echo "$out" | grep -c .)
nodes=$(kubectl get nodes --no-headers | wc -l)
[ "${lines:-0}" -eq "${nodes:-0}" ] 2>/dev/null && ok "$lines lines for $nodes nodes" \
                                                || no "got ${lines:-0} lines for ${nodes:-0} nodes"

echo "== 2. Without a range it is one line (32.4) =="
one=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | grep -c .)
[ "${one:-0}" -eq 1 ] 2>/dev/null && ok "space-separated on a single line, as expected" \
                                  || no "expected 1 line, got ${one:-0}"

echo "== 3. custom-columns builds a table (32.5) =="
t=$(kubectl get nodes -o custom-columns=NODE:.metadata.name,CPU:.status.capacity.cpu 2>/dev/null)
echo "$t" | head -1 | grep -q "NODE" && ok "the header row is present" || no "no header in the output"
echo "$t" | tail -n +2 | awk 'NF==2' | grep -q . && ok "  rows have two columns" || no "  rows are malformed"

echo "== 4. A filter selects a subset (32.2) =="
node=$(kubectl get pods -n $NS -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)
if [ -n "$node" ]; then
  f=$(kubectl get pods -n $NS -o jsonpath="{range .items[?(@.spec.nodeName==\"$node\")]}{.metadata.name}{\"\n\"}{end}" 2>/dev/null | grep -c .)
  a=$(kubectl get pods -n $NS --field-selector "spec.nodeName=$node" --no-headers 2>/dev/null | wc -l)
  [ "${f:-0}" -eq "${a:-0}" ] 2>/dev/null && ok "the JSONPath filter and the field selector agree ($f pods on $node)" \
                                          || no "filter returned ${f:-0}, field selector ${a:-0}"
else
  no "could not read a node name from the first pod"
fi

echo "== 5. An escaped key is readable (32.3) =="
owner=$(kubectl get deploy web -n $NS -o jsonpath='{.metadata.annotations.example\.com/owner}' 2>/dev/null)
[ "$owner" = "platform-team" ] && ok "escaped annotation key -> $owner" \
                              || no "got '${owner:-nothing}', expected platform-team"
bad=$(kubectl get deploy web -n $NS -o jsonpath='{.metadata.annotations.example.com/owner}' 2>/dev/null)
[ -z "$bad" ] && ok "  ...and the UNescaped form returns nothing (silently)" \
              || no "  the unescaped form unexpectedly returned '$bad'"

echo "== 6. --sort-by takes a bare path (32.6) =="
kubectl get pods -n $NS --sort-by=.metadata.creationTimestamp >/dev/null 2>&1 \
  && ok "--sort-by=.metadata.creationTimestamp works" || no "--sort-by failed"
kubectl get nodes --sort-by=.status.capacity.cpu >/dev/null 2>&1 \
  && ok "  and works on nodes by CPU" || no "  sorting nodes by CPU failed"

echo "== 7. custom-columns-file avoids quoting entirely (32.8) =="
printf 'NODE\tCPU\n.metadata.name\t.status.capacity.cpu\n' > /tmp/cka32-verify-cols.txt
kubectl get nodes -o custom-columns-file=/tmp/cka32-verify-cols.txt 2>/dev/null | grep -q "NODE" \
  && ok "custom-columns-file produced a table" || no "custom-columns-file failed"
rm -f /tmp/cka32-verify-cols.txt

echo "== 8. Lists inside an object (32.5) =="
imgs=$(kubectl get deploy web -n $NS -o jsonpath='{.spec.template.spec.containers[*].image}' 2>/dev/null | wc -w)
[ "${imgs:-0}" -eq 2 ] 2>/dev/null && ok "the web Deployment reports $imgs container images" \
                                   || no "expected 2 images, got ${imgs:-0}"

echo "== 9. go-template does what JSONPath cannot (32.7) =="
g=$(kubectl get deploy -n $NS -o go-template='{{range .items}}{{if ge .spec.replicas 3.0}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' 2>/dev/null | grep -c .)
[ "${g:-0}" -ge 1 ] 2>/dev/null && ok "a numeric comparison found $g Deployment(s) with >= 3 replicas" \
                                || no "the go-template numeric comparison returned nothing"

echo "== 10. Secrets decode (32.5) =="
sec=$(kubectl get secret app-secret -n $NS -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null)
[ "$sec" = "s3cr3t-value" ] && ok "the Secret decoded correctly" || no "got '${sec:-nothing}'"

echo
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
