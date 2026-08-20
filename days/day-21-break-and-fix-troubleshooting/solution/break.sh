#!/usr/bin/env bash
# Day 21 -- break the DevBoard stack in a specific, diagnosable way.
#
#   bash break.sh            list the scenarios
#   bash break.sh 3          apply scenario 3
#   bash break.sh reset      rebuild a known-good stack
#   bash break.sh 9          THREE faults at once (do this one last)
#
# Then diagnose it yourself. The answers are in scenario-NN.md -- do not open
# one until you have fixed it, or spent 10 minutes.
set -uo pipefail
NS=devboard
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK="${HERE}/../../day-12-wire-the-three-tier-app/solution"

reset_stack() {
  echo "==> rebuilding a known-good stack in namespace ${NS}"
  kubectl delete namespace "${NS}" --wait=true 2>/dev/null || true
  kubectl apply -f "${STACK}/"
  kubectl rollout status deployment/postgres -n "${NS}" --timeout=180s
  kubectl rollout status deployment/backend  -n "${NS}" --timeout=180s
  kubectl rollout status deployment/frontend -n "${NS}" --timeout=180s
  echo
  echo "Healthy. Verify:  curl -s -o /dev/null -w '%{http_code}\n' http://localhost:30080/api/tasks"
}

case "${1:-list}" in

  list)
    cat <<'EOF'
Day 21 scenarios
================
  1  Backend pods Running, but the UI shows no tasks
  2  Frontend pods will not start
  3  Backend CrashLoopBackOff after a config change
  4  Postgres will not schedule
  5  Backend Running but never Ready
  6  Backend restarts constantly, exit code 137
  7  Scaling the backend leaves pods Pending
  8  Everything healthy, but a client gets 403 Forbidden
  9  THREE faults at once -- no hints. Time yourself.

Usage:
  bash break.sh reset      rebuild a known-good stack
  bash break.sh <n>        break it
  cat scenario-0<n>.md     the answer (only after you have tried)
EOF
    ;;

  reset)
    reset_stack
    ;;

  1)
    echo "==> scenario 1 applied. Symptom: the UI loads but shows no tasks."
    kubectl patch svc backend -n "${NS}" \
      -p '{"spec":{"selector":{"app":"devboard-backend"}}}' >/dev/null
    ;;

  2)
    echo "==> scenario 2 applied. Symptom: frontend pods will not start."
    kubectl set image deployment/frontend frontend=devboard-frontend:latest -n "${NS}" >/dev/null
    kubectl patch deployment frontend -n "${NS}" --type=json \
      -p '[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"Always"}]' >/dev/null
    ;;

  3)
    echo "==> scenario 3 applied. Symptom: backend CrashLoopBackOff."
    kubectl patch configmap devboard-config -n "${NS}" \
      -p '{"data":{"POSTGRES_HOST":"postgres-db"}}' >/dev/null
    kubectl rollout restart deployment/backend -n "${NS}" >/dev/null
    ;;

  4)
    echo "==> scenario 4 applied. Symptom: postgres will not schedule."
    kubectl delete deployment postgres -n "${NS}" --ignore-not-found >/dev/null
    kubectl apply -f "${HERE}/broken/04-postgres-bad-pvc.yaml" >/dev/null
    ;;

  5)
    echo "==> scenario 5 applied. Symptom: backend Running but never Ready."
    kubectl patch deployment backend -n "${NS}" -p \
      '{"spec":{"template":{"spec":{"containers":[{"name":"backend","readinessProbe":{"httpGet":{"path":"/healthz","port":8080},"periodSeconds":3,"failureThreshold":2}}]}}}}' >/dev/null
    ;;

  6)
    echo "==> scenario 6 applied. Symptom: backend restarting constantly."
    kubectl patch deployment backend -n "${NS}" -p \
      '{"spec":{"template":{"spec":{"containers":[{"name":"backend","resources":{"requests":{"memory":"8Mi"},"limits":{"memory":"8Mi"}}}]}}}}' >/dev/null
    ;;

  7)
    echo "==> scenario 7 applied. Now run: kubectl scale deployment backend --replicas=8 -n ${NS}"
    kubectl patch deployment backend -n "${NS}" -p \
      '{"spec":{"template":{"spec":{"containers":[{"name":"backend","resources":{"requests":{"cpu":"900m","memory":"64Mi"}}}]}}}}' >/dev/null
    kubectl scale deployment backend --replicas=8 -n "${NS}" >/dev/null
    ;;

  8)
    echo "==> scenario 8 applied. Symptom: the reporting pod gets 403 Forbidden."
    kubectl apply -f "${HERE}/broken/08-rbac-broken.yaml" >/dev/null
    echo "    Reproduce with:"
    echo "      kubectl exec -n ${NS} reporting -- kubectl get deployments -n ${NS}"
    ;;

  9)
    echo "==> scenario 9: THREE faults applied. No hints. Time yourself."
    kubectl patch svc postgres -n "${NS}" \
      -p '{"spec":{"ports":[{"name":"postgres","port":5432,"targetPort":5433}]}}' >/dev/null
    kubectl patch deployment frontend -n "${NS}" -p \
      '{"spec":{"template":{"spec":{"containers":[{"name":"frontend","livenessProbe":{"httpGet":{"path":"/","port":4173},"initialDelaySeconds":1,"periodSeconds":1,"timeoutSeconds":1,"failureThreshold":1}}]}}}}' >/dev/null
    kubectl patch configmap devboard-config -n "${NS}" \
      -p '{"data":{"POSTGRES_DB":"devbaord"}}' >/dev/null
    kubectl rollout restart deployment/backend -n "${NS}" >/dev/null
    ;;

  *)
    echo "unknown scenario: ${1}"
    echo "run 'bash break.sh' for the list"
    exit 1
    ;;
esac
