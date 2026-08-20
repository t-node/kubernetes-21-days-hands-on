#!/usr/bin/env bash
# CKA 29 verification. Run from the assignment directory:
#   bash solution/verify.sh
#
# Almost everything here runs WITHOUT a cluster -- `kubectl kustomize` renders
# locally. Only the last section needs one, and it is skipped if unavailable.
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok() { echo "  PASS  $1"; pass=$((pass+1)); }
no() { echo "  FAIL  $1"; fail=$((fail+1)); }
K() { kubectl kustomize "$@" 2>/dev/null; }

echo "== 0. Tooling =="
kubectl kustomize --help >/dev/null 2>&1 && ok "kubectl kustomize is available (29.3)" || {
  no "kubectl kustomize not available"; echo; echo "== 0 passed, 1 failed =="; exit 1; }

echo "== 1. Each directory builds on its own (29.5) =="
for d in api web db; do
  n=$(K "${HERE}/base/$d" | grep -c "^kind:")
  [ "${n:-0}" -eq 2 ] 2>/dev/null && ok "  base/$d renders $n objects" \
                                  || no "  base/$d rendered ${n:-0} objects, expected 2"
done
total=$(K "${HERE}/base" | grep -c "^kind:")
[ "${total:-0}" -eq 7 ] 2>/dev/null && ok "the root renders $total objects (3 dirs + a generator)" \
                                    || no "the root rendered ${total:-0}, expected 7"

echo "== 2. The generated ConfigMap and its hash (29.7) =="
out=$(K "${HERE}/base")
cmname=$(echo "$out" | grep -m1 "name: app-config-" | awk '{print $2}')
case "$cmname" in
  app-config-*) ok "the ConfigMap name carries a content hash: $cmname" ;;
  *) no "no hashed ConfigMap name found (got '${cmname:-nothing}')" ;;
esac
ref=$(echo "$out" | grep -A1 "configMapRef" | grep "name:" | awk '{print $2}')
[ -n "$ref" ] && [ "$ref" = "$cmname" ] && ok "  the configMapRef was rewritten to match" \
                                        || no "  configMapRef is '${ref:-none}', ConfigMap is '$cmname'"

# change a literal in a COPY, so the repo is left untouched
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cp -r "${HERE}/base" "$TMP/base"
sed -i 's/GREETING=hello-from-base/GREETING=changed/' "$TMP/base/kustomization.yaml" 2>/dev/null
new=$(kubectl kustomize "$TMP/base" 2>/dev/null | grep -m1 "name: app-config-" | awk '{print $2}')
[ -n "$new" ] && [ "$new" != "$cmname" ] && ok "  changing a literal changes the hash ($new)" \
                                         || no "  the hash did not change when a literal did"

echo "== 3. Transformers (29.6) =="
t=$(K "${HERE}/transformers")
echo "$t" | grep -q "name: prod-web-v2" && ok "namePrefix and nameSuffix renamed the objects" \
                                        || no "objects were not renamed as expected"
echo "$t" | grep -q "namespace: cka29" && ok "  namespace was set" || no "  namespace not set"
echo "$t" | grep -q "owner: platform-team" && ok "  commonAnnotations applied" || no "  no annotation"

echo "== 4. References were rewritten, not just names (29.6) =="
echo "$t" | grep -A1 "name: DB_HOST" | grep -q "value: prod-db-v2" \
  && ok "  the DB_HOST env var points at the renamed Service" \
  || no "  DB_HOST was not rewritten"
echo "$t" | grep -A1 "name: API_URL" | grep -q "prod-api-v2" \
  && ok "  the API_URL inside a string was rewritten" \
  || no "  API_URL was not rewritten"
echo "$t" | grep -q "serviceName: prod-db-v2" \
  && ok "  the StatefulSet's serviceName was rewritten" \
  || no "  serviceName was not rewritten"

echo "== 5. images and replicas (29.6) =="
imgs=$(echo "$t" | grep -c "image: nginx:1.27.2-alpine")
[ "${imgs:-0}" -eq 3 ] 2>/dev/null && ok "  images matched by IMAGE NAME in all 3 objects" \
                                   || no "  ${imgs:-0} containers got the new tag, expected 3"
echo "$t" | awk '/name: prod-web-v2$/,/replicas:/' | grep -q "replicas: 4" \
  && ok "  replicas matched web by its PRE-prefix name" \
  || no "  the replicas transformer did not take effect on web"

echo "== 6. The selector trap (29.6) =="
safe=$(K "${HERE}/safe-labels")
unsafe=$(K "${HERE}/unsafe-labels-BAD")
echo "$safe" | awk '/matchLabels:/,/template:/' | grep -q "build:" \
  && no "  includeSelectors: false still wrote into the selector" \
  || ok "  includeSelectors: false kept the changing label OUT of the selector"
echo "$unsafe" | awk '/matchLabels:/,/template:/' | grep -q "build:" \
  && ok "  includeSelectors: true DID write into the immutable selector (the trap)" \
  || no "  the unsafe example did not reproduce the trap"
echo "$safe" | grep -q "build:" && ok "  ...and the label is still on the objects" \
                                || no "  the label is missing entirely from the safe render"

echo "== 7. Against a cluster (optional) =="
if kubectl get ns >/dev/null 2>&1; then
  d=$(kubectl diff -k "${HERE}/base" 2>&1 | head -1)
  ok "kubectl diff -k ran (29.8)"
  echo "        first line: ${d:-<no differences>}"
else
  echo "  SKIP  no cluster reachable"
fi

echo
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
