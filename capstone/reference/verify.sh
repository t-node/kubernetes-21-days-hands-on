#!/usr/bin/env bash
# End-to-end verification of the DevBoard deployment.
# Exits non-zero on the first failure, so it is usable in CI.
#
#   bash verify.sh
set -uo pipefail
NS=devboard
HOST=devboard.local
FAILED=0

pass() { printf "  \033[32mPASS\033[0m  %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m  %s\n" "$1"; FAILED=$((FAILED+1)); }
head() { printf "\n\033[1m%s\033[0m\n" "$1"; }

check() {  # check <description> <command...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "${desc}"; else fail "${desc}"; fi
}

expect() {  # expect <description> <expected> <command...>
  local desc="$1" want="$2"; shift 2
  local got
  got="$("$@" 2>/dev/null | tr -d '\r')"
  if [ "${got}" = "${want}" ]; then pass "${desc}"
  else fail "${desc} (want '${want}', got '${got}')"; fi
}

head "1. Namespace and governance"
check "namespace exists"        kubectl get ns "${NS}"
check "ResourceQuota present"   kubectl get resourcequota devboard-quota -n "${NS}"
check "LimitRange present"      kubectl get limitrange devboard-limits -n "${NS}"

head "2. Workloads"
expect "postgres StatefulSet ready" "1" \
  kubectl get statefulset postgres -n "${NS}" -o jsonpath='{.status.readyReplicas}'
check "backend deployment available" \
  kubectl wait --for=condition=Available deployment/backend -n "${NS}" --timeout=120s
check "frontend deployment available" \
  kubectl wait --for=condition=Available deployment/frontend -n "${NS}" --timeout=120s

head "3. Service wiring (endpoints must not be empty)"
for svc in postgres backend frontend; do
  eps="$(kubectl get endpoints "${svc}" -n "${NS}" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)"
  if [ -n "${eps}" ]; then pass "service/${svc} has endpoints"
  else fail "service/${svc} has NO endpoints"; fi
done

head "4. Persistence"
check "PVC bound" \
  bash -c "kubectl get pvc data-postgres-0 -n ${NS} -o jsonpath='{.status.phase}' | grep -q Bound"
check "schema present" \
  kubectl exec -n "${NS}" postgres-0 -- psql -U devboard -d devboard -c '\dt tasks'

head "5. Security posture"
for sa in devboard-postgres devboard-backend devboard-frontend; do
  check "serviceaccount/${sa} exists" kubectl get sa "${sa}" -n "${NS}"
done
for wl in "statefulset/postgres" "deployment/backend" "deployment/frontend"; do
  expect "${wl} does not mount an API token" "false" \
    kubectl get "${wl}" -n "${NS}" -o jsonpath='{.spec.template.spec.automountServiceAccountToken}'
  expect "${wl} runs as non-root" "true" \
    kubectl get "${wl}" -n "${NS}" -o jsonpath='{.spec.template.spec.securityContext.runAsNonRoot}'
done

OP="system:serviceaccount:${NS}:devboard-operator"
expect "operator CAN list pods"      "yes" kubectl auth can-i list pods       -n "${NS}" --as="${OP}"
expect "operator CAN read logs"      "yes" kubectl auth can-i get  pods/log   -n "${NS}" --as="${OP}"
expect "operator CANNOT read secrets" "no" kubectl auth can-i get  secrets    -n "${NS}" --as="${OP}"
expect "operator CANNOT exec"         "no" kubectl auth can-i create pods/exec -n "${NS}" --as="${OP}"
expect "operator CANNOT delete pods"  "no" kubectl auth can-i delete pods     -n "${NS}" --as="${OP}"

head "6. Resilience and scaling"
check "backend PDB present"  kubectl get pdb backend  -n "${NS}"
check "frontend PDB present" kubectl get pdb frontend -n "${NS}"
check "HPA present"          kubectl get hpa backend  -n "${NS}"
hpa_metric="$(kubectl get hpa backend -n "${NS}" \
  -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null)"
if [ -n "${hpa_metric}" ]; then pass "HPA is reading metrics (${hpa_metric}%)"
else fail "HPA metric is <unknown> -- metrics-server, or a missing CPU request"; fi

replicas_field="$(kubectl get deployment backend -n "${NS}" -o json \
  | python -c "import sys,json; print('set' if 'replicas' in json.load(sys.stdin)['spec'] else 'absent')" 2>/dev/null)"
# NOTE: the API server always materialises spec.replicas, so this is informational.
printf "  \033[33mINFO\033[0m  backend spec.replicas is %s in the live object (expected: the manifest omits it)\n" "${replicas_field}"

head "7. End to end through the Ingress"
check "ingress exists" kubectl get ingress devboard -n "${NS}"

code_ui="$(curl -sk -o /dev/null -w '%{http_code}' -H "Host: ${HOST}" https://localhost:8443/ || echo 000)"
code_api="$(curl -sk -o /dev/null -w '%{http_code}' -H "Host: ${HOST}" https://localhost:8443/api/tasks || echo 000)"
code_prj="$(curl -sk -o /dev/null -w '%{http_code}' -H "Host: ${HOST}" https://localhost:8443/api/projects || echo 000)"

[ "${code_ui}"  = "200" ] && pass "UI returns 200"            || fail "UI returned ${code_ui}"
[ "${code_api}" = "200" ] && pass "/api/tasks returns 200"    || fail "/api/tasks returned ${code_api} (rewrite? endpoints?)"
[ "${code_prj}" = "200" ] && pass "/api/projects returns 200" || fail "/api/projects returned ${code_prj}"

body="$(curl -sk -H "Host: ${HOST}" https://localhost:8443/api/tasks || true)"
case "${body}" in
  *'"tasks"'*) pass "API returns task JSON" ;;
  *)           fail "API body did not look like task JSON" ;;
esac

head "Result"
if [ "${FAILED}" -eq 0 ]; then
  printf "\033[32mAll checks passed.\033[0m\n"
  exit 0
else
  printf "\033[31m%d check(s) failed.\033[0m\n" "${FAILED}"
  echo
  echo "Start here:"
  echo "  kubectl get pods -n ${NS}"
  echo "  kubectl get endpoints -n ${NS}"
  echo "  kubectl get events -n ${NS} --sort-by=.lastTimestamp | tail -20"
  exit 1
fi
