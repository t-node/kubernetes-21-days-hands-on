#!/usr/bin/env bash
# CKA 28 verification. Run from the assignment directory:
#   bash solution/verify.sh
#
# Most checks need only `helm template` and no cluster. The release checks are
# skipped if the cka28 releases are not installed.
NS=${NS:-cka28}
HERE="$(cd "$(dirname "$0")" && pwd)"
CHART="${HERE}/mychart"
pass=0; fail=0
ok() { echo "  PASS  $1"; pass=$((pass+1)); }
no() { echo "  FAIL  $1"; fail=$((fail+1)); }

echo "== 0. Helm =="
if command -v helm >/dev/null 2>&1; then
  v=$(helm version --short 2>/dev/null)
  case "$v" in
    v3.*) ok "helm $v" ;;
    *) no "unexpected helm version: ${v:-unknown} (this assignment is Helm 3)" ;;
  esac
else
  no "helm is not installed -- see Step 0"
  echo; echo "== 0 passed, 1 failed =="; exit 1
fi

echo "== 1. The chart is well formed (28.4) =="
for f in Chart.yaml values.yaml templates/_helpers.tpl templates/deployment.yaml \
         templates/service.yaml templates/configmap.yaml templates/ingress.yaml templates/NOTES.txt; do
  [ -f "${CHART}/${f}" ] && ok "  $f" || no "  $f missing"
done
grep -q "^apiVersion: v2" "${CHART}/Chart.yaml" && ok "  apiVersion: v2 (Helm 3)" \
                                                || no "  Chart.yaml is not apiVersion v2"
helm lint "$CHART" >/dev/null 2>&1 && ok "  helm lint passes" || { no "  helm lint failed:"; helm lint "$CHART" | sed 's/^/        /'; }

echo "== 2. Default render (28.5) =="
out=$(helm template t "$CHART" 2>/dev/null)
for k in Deployment Service ConfigMap; do
  echo "$out" | grep -q "^kind: $k" && ok "  renders a $k" || no "  no $k in the default render"
done
echo "$out" | grep -q "^kind: Ingress" && no "  an Ingress was rendered by default (ingress.enabled should be false)" \
                                       || ok "  no Ingress by default (the if-wrapped file emitted nothing)"
echo "$out" | grep -q "image: \"nginx:1.27-alpine\"" \
  && ok "  the image tag fell back to .Chart.AppVersion" \
  || no "  the image tag did not default to appVersion"

echo "== 3. Values change the output (28.1) =="
r=$(helm template t "$CHART" --set replicaCount=7 2>/dev/null | grep -m1 "replicas:")
case "$r" in *7*) ok "  --set replicaCount=7 -> $r" ;; *) no "  --set did not take effect ($r)" ;; esac

pout=$(helm template t "$CHART" -f "${HERE}/values-prod.yaml" 2>/dev/null)
echo "$pout" | grep -q "^kind: Ingress" && ok "  -f values-prod.yaml adds an Ingress" \
                                        || no "  the prod values did not enable the Ingress"
echo "$pout" | grep -q "replicas: 4" && ok "  ...and sets replicas: 4" || no "  prod replicas not applied"
echo "$pout" | grep -q 'debug: "false"' && ok "  a boolean value was quoted for the ConfigMap" \
                                        || no "  the boolean was not quoted -- the ConfigMap would be invalid"

echo "== 4. The required guard (28.5) =="
if helm template t "$CHART" -f "${HERE}/values-broken.yaml" >/dev/null 2>&1; then
  no "  the broken values file rendered -- the required guard is not working"
else
  msg=$(helm template t "$CHART" -f "${HERE}/values-broken.yaml" 2>&1 | grep -o "values.owner is required.*" | head -1)
  [ -n "$msg" ] && ok "  it failed with the author's message: $msg" \
                || ok "  it failed to render (as intended)"
fi

echo "== 5. Selector labels exclude anything that changes =="
sel=$(helm template t "$CHART" 2>/dev/null | awk '/^kind: Deployment/,/^---/' | awk '/matchLabels:/{f=1;next} /template:/{f=0} f')
echo "$sel" | grep -q "helm.sh/chart" \
  && no "  the selector contains helm.sh/chart -- every upgrade would fail" \
  || ok "  the selector has no chart version in it"
echo "$sel" | grep -q "app.kubernetes.io/instance" && ok "  it does contain the release instance" \
                                                   || no "  no instance label in the selector"

echo "== 6. The checksum annotation (28.5) =="
a=$(helm template t "$CHART" 2>/dev/null | grep -m1 "checksum/config:")
[ -n "$a" ] && ok "  present:${a#*checksum/config:}" || no "  no checksum/config annotation"
b=$(helm template t "$CHART" --set config.greeting=different 2>/dev/null | grep -m1 "checksum/config:")
[ -n "$a" ] && [ "$a" != "$b" ] && ok "  it changes when a config value changes" \
                                || no "  the checksum did not change -- pods would not roll"

echo "== 7. Installed releases (optional) =="
if helm list -n "$NS" 2>/dev/null | grep -q myapp; then
  ok "release myapp exists in $NS"
  helm list -n "$NS" | grep -q myapp-two && ok "  and myapp-two, from the same chart" \
                                         || echo "  NOTE  myapp-two not installed (Step 6)"
  n=$(kubectl get secrets -n "$NS" -l owner=helm --no-headers 2>/dev/null | wc -l)
  [ "${n:-0}" -ge 1 ] 2>/dev/null && ok "  $n helm release Secret(s) -- one per revision (28.7)" \
                                  || no "  no release Secrets found"
  t=$(kubectl get secrets -n "$NS" -l owner=helm -o jsonpath='{.items[0].type}' 2>/dev/null)
  [ "$t" = "helm.sh/release.v1" ] && ok "  their type is $t" || no "  unexpected Secret type '$t'"
  d1=$(kubectl get deploy -n "$NS" -l app.kubernetes.io/instance=myapp -o name 2>/dev/null | head -1)
  d2=$(kubectl get deploy -n "$NS" -l app.kubernetes.io/instance=myapp-two -o name 2>/dev/null | head -1)
  [ -n "$d1" ] && [ "$d1" != "$d2" ] && ok "  the two releases produced distinct Deployments" \
                                     || echo "  NOTE  could not compare the two releases"
else
  echo "  SKIP  no myapp release in $NS -- run Step 6 to check this section"
fi

echo
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
