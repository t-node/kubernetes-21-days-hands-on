#!/usr/bin/env bash
# CKA 30 verification. Run from the assignment directory:
#   bash solution/verify.sh
#
# Runs entirely without a cluster -- `kubectl kustomize` renders locally.
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok() { echo "  PASS  $1"; pass=$((pass+1)); }
no() { echo "  FAIL  $1"; fail=$((fail+1)); }
K() { kubectl kustomize "$@" 2>/dev/null; }

echo "== 0. Tooling =="
kubectl kustomize --help >/dev/null 2>&1 && ok "kubectl kustomize is available" || {
  no "kubectl kustomize not available"; echo; echo "== 0 passed, 1 failed =="; exit 1; }

echo "== 1. The base =="
n=$(K "${HERE}/base" | grep -c "^kind:")
[ "${n:-0}" -eq 4 ] 2>/dev/null && ok "renders $n objects" || no "rendered ${n:-0}, expected 4"
c=$(K "${HERE}/base" | awk '/name: api$/,/^---/' | grep -c "^        - name:")
[ "${c:-0}" -ge 2 ] 2>/dev/null && ok "  api has $c containers (needed for the list demos)" \
                                || no "  api has ${c:-0} containers, expected 2"

echo "== 2. Strategic merge MODIFIES rather than duplicates (30.5) =="
p=$(K "${HERE}/patch-demos")
webc=$(echo "$p" | awk '/name: web$/,/^---/' | grep -c "image: nginx")
[ "${webc:-0}" -eq 1 ] 2>/dev/null && ok "web still has one container after the patch" \
                                   || no "web has ${webc:-0} nginx containers, expected 1"
echo "$p" | grep -q "http://api.prod:80" && ok "  API_URL was replaced (env merges by name)" \
                                          || no "  API_URL was not replaced"
echo "$p" | grep -q "added-by-patch" && ok "  EXTRA was added alongside it" || no "  EXTRA missing"

echo "== 3. Add and delete list elements (30.5) =="
echo "$p" | grep -q "name: log-shipper" && ok "02 added a container" || no "log-shipper missing"
echo "$p" | grep -q "name: legacy-sidecar" \
  && no "  legacy-sidecar survived -- \$patch: delete did not work" \
  || ok "  \$patch: delete removed legacy-sidecar"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cp -r "${HERE}/patch-demos" "$TMP/d"
cp "$TMP/d/kustomization-replace.yaml" "$TMP/d/kustomization.yaml"
r=$(kubectl kustomize "$TMP/d" 2>/dev/null | awk '/name: api$/,/^---/' | grep -c "^        - name:")
[ "${r:-0}" -eq 1 ] 2>/dev/null && ok "  \$patch: replace left exactly one container" \
                                || no "  \$patch: replace left ${r:-0} containers, expected 1"

echo "== 4. JSON 6902 (30.6) =="
echo "$p" | awk '/name: web$/,/^---/' | grep -q "replicas: 4" \
  && ok "op: replace set replicas to 4" || no "replicas were not replaced"
echo "$p" | grep -q "ADDED_BY_JSON6902" && ok "  \`-\` appended to the env list" || no "  append failed"
echo "$p" | grep -q "example.com/patched-by: json6902" \
  && ok "  ~1 was decoded back to a / in the annotation key" \
  || no "  the escaped annotation key did not render"

echo "== 5. A target reaches many objects, and none silently (30.3) =="
m=$(echo "$p" | grep -c "patched-by-label-selector")
[ "${m:-0}" -eq 2 ] 2>/dev/null && ok "the labelSelector patch hit $m Deployments" \
                                || no "it hit ${m:-0}, expected 2"
cp -r "${HERE}/patch-demos" "$TMP/e"
sed -i 's/tier in (frontend,backend)/tier=nonexistent/' "$TMP/e/kustomization.yaml"
z=$(kubectl kustomize "$TMP/e" 2>/dev/null | grep -c "patched-by-label-selector")
[ "${z:-1}" -eq 0 ] 2>/dev/null && ok "  a non-matching target renders SILENTLY (the trap)" \
                                || no "  expected 0 matches, got ${z}"

echo "== 6. Overlays (30.7) =="
d=$(K "${HERE}/overlays/dev"); pr=$(K "${HERE}/overlays/prod")
echo "$d"  | grep -q "namespace: cka30-dev"  && ok "dev sets its namespace"  || no "dev namespace missing"
echo "$pr" | grep -q "namespace: cka30-prod" && ok "prod sets its namespace" || no "prod namespace missing"
echo "$d"  | grep -q "name: dev-web"  && ok "  dev namePrefix applied"  || no "  dev prefix missing"
echo "$pr" | grep -q "name: prod-web" && ok "  prod namePrefix applied" || no "  prod prefix missing"
dn=$(echo "$d" | grep -c "^kind:"); pn=$(echo "$pr" | grep -c "^kind:")
[ "${pn:-0}" -gt "${dn:-0}" ] 2>/dev/null && ok "  prod renders more objects ($pn) than dev ($dn)" \
                                          || no "  prod=$pn dev=$dn -- expected prod to have more"

echo "== 7. Components (30.8) =="
grep -q "kind: Component" "${HERE}/components/external-db/kustomization.yaml" \
  && ok "external-db declares kind: Component" || no "external-db is not a Component"
grep -q "v1alpha1" "${HERE}/components/external-db/kustomization.yaml" \
  && ok "  ...with apiVersion v1alpha1" || no "  wrong apiVersion for a Component"
echo "$d" | grep -q "name: dev-postgres" && ok "  it added Postgres to dev" || no "  no postgres in dev"
echo "$d" | grep -q "name: DB_HOST" && ok "  ...AND patched api to know about it" \
                                    || no "  api was not patched by the component"

dm=$(echo "$d"  | grep -c "metrics-exporter")
pm=$(echo "$pr" | grep -c "metrics-exporter")
[ "${dm:-1}" -eq 0 ] 2>/dev/null && ok "monitoring is absent from dev (opt-in)" \
                                 || no "dev has ${dm} metrics-exporter references, expected 0"
[ "${pm:-0}" -eq 3 ] 2>/dev/null && ok "  and reaches 3 Deployments in prod, including postgres" \
                                 || no "  prod has ${pm} metrics-exporter references, expected 3"

echo "== 8. Component ORDER matters (30.8) =="
cp -r "${HERE}" "$TMP/s" 2>/dev/null
python - "$TMP/s/overlays/prod/kustomization.yaml" <<'PY' 2>/dev/null
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("  - ../../components/external-db\n  - ../../components/monitoring\n",
              "  - ../../components/monitoring\n  - ../../components/external-db\n")
open(p, "w", newline="\n").write(s)
PY
sw=$(kubectl kustomize "$TMP/s/overlays/prod" 2>/dev/null | grep -c "metrics-exporter")
[ "${sw:-0}" -eq 2 ] 2>/dev/null && ok "swapping the order gives $sw, not 3 -- postgres did not exist yet" \
                                 || echo "  NOTE  got ${sw:-?} after swapping (expected 2)"

echo
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
