#!/usr/bin/env bash
# CKA 11 verification. Run from the assignment directory:
#   bash solution/verify.sh
#
# Checks whichever parts of the lab are reachable: the resize-lab cluster for
# part B, the devops cluster for part C.
NS=cka11
pass=0; fail=0; skip=0
ok()  { echo "  PASS  $1"; pass=$((pass+1)); }
no()  { echo "  FAIL  $1"; fail=$((fail+1)); }
sk()  { echo "  SKIP  $1"; skip=$((skip+1)); }

echo "== part B: in-place resize (cluster kind-resize-lab) =="
if kubectl config get-contexts -o name 2>/dev/null | grep -q '^kind-resize-lab$'; then
  K="kubectl --context=kind-resize-lab"
  if docker exec resize-lab-control-plane grep -q "InPlacePodVerticalScaling" \
       /etc/kubernetes/manifests/kube-apiserver.yaml 2>/dev/null; then
    ok "the feature gate is on the API server"
  else
    no "InPlacePodVerticalScaling missing from the API server manifest"
  fi
  if docker exec resize-lab-control-plane grep -q "InPlacePodVerticalScaling" \
       /var/lib/kubelet/config.yaml 2>/dev/null; then
    ok "the feature gate is on the kubelet (this is the one people forget)"
  else
    no "InPlacePodVerticalScaling missing from the kubelet config"
  fi

  rp=$($K get pod resizable -n $NS -o jsonpath='{.spec.containers[0].resizePolicy}' 2>/dev/null)
  case "$rp" in
    *NotRequired*RestartContainer*|*RestartContainer*NotRequired*) ok "resizePolicy declares both cpu and memory" ;;
    "") no "pod 'resizable' not found in $NS on kind-resize-lab" ;;
    *) no "resizePolicy looks incomplete: $rp" ;;
  esac

  alloc=$($K get pod resizable -n $NS -o jsonpath='{.status.containerStatuses[0].allocatedResources.cpu}' 2>/dev/null)
  [ -n "$alloc" ] && ok "the node reported allocatedResources.cpu = $alloc" \
                  || no "no allocatedResources on the pod status"

  st=$($K get pod resizable -n $NS -o jsonpath='{.status.resize}' 2>/dev/null)
  case "${st:-none}" in
    none|"") ok "status.resize is clear -- no resize is pending" ;;
    Infeasible) echo "  NOTE  status.resize is Infeasible -- expected if you left the 64-CPU patch applied" ;;
    *) echo "  NOTE  status.resize is '$st'" ;;
  esac
else
  sk "no kind-resize-lab context -- part B not run, or the cluster was deleted"
fi

echo "== part C: VPA (cluster kind-devops) =="
if kubectl --context=kind-devops get crd verticalpodautoscalers.autoscaling.k8s.io >/dev/null 2>&1; then
  K="kubectl --context=kind-devops"
  ok "the VerticalPodAutoscaler CRD is registered"

  for d in vpa-recommender vpa-updater vpa-admission-controller; do
    r=$($K -n kube-system get deploy "$d" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    [ "${r:-0}" -ge 1 ] 2>/dev/null && ok "  $d is ready" || no "  $d not ready (readyReplicas=${r:-0})"
  done

  $K get mutatingwebhookconfiguration 2>/dev/null | grep -qi vpa \
    && ok "the VPA mutating webhook is registered" \
    || no "no VPA mutating webhook -- pods would never be resized on creation"

  if $K get vpa hungry-vpa -n $NS >/dev/null 2>&1; then
    ok "the hungry-vpa object exists"
    mode=$($K get vpa hungry-vpa -n $NS -o jsonpath='{.spec.updatePolicy.updateMode}' 2>/dev/null)
    echo "        updateMode = ${mode:-unset}"

    t=$($K get vpa hungry-vpa -n $NS \
          -o jsonpath='{.status.recommendation.containerRecommendations[0].target.cpu}' 2>/dev/null)
    u=$($K get vpa hungry-vpa -n $NS \
          -o jsonpath='{.status.recommendation.containerRecommendations[0].uncappedTarget.cpu}' 2>/dev/null)
    if [ -n "$t" ]; then
      ok "a recommendation exists (target cpu = $t, uncapped = ${u:-n/a})"
      [ -n "$u" ] && [ "$t" != "$u" ] \
        && ok "  target differs from uncappedTarget -- maxAllowed is binding, as designed" \
        || echo "  NOTE  target == uncappedTarget; give the recommender more time under load"
    else
      no "no recommendation yet -- check metrics-server and wait a few minutes"
    fi

    if [ "$mode" = "Recreate" ] || [ "$mode" = "Auto" ]; then
      $K get events -n $NS 2>/dev/null | grep -qi "EvictedByVPA" \
        && ok "an EvictedByVPA event was recorded" \
        || echo "  WAIT  no eviction yet; the updater acts on its own schedule"
    fi
  else
    sk "no hungry-vpa in $NS"
  fi
else
  sk "the VPA is not installed on kind-devops"
fi

echo
echo "== $pass passed, $fail failed, $skip skipped =="
[ "$fail" -eq 0 ]
