#!/usr/bin/env bash
# Install the Vertical Pod Autoscaler.
#
#   bash solution/install-vpa.sh            # install
#   bash solution/install-vpa.sh uninstall  # remove
#
# The VPA is NOT part of Kubernetes -- it lives in kubernetes/autoscaler and is
# installed from that repo's hack/vpa-up.sh, which also generates the TLS
# certificate its admission webhook needs (CKA 07 territory).
#
# Override the version if your cluster needs a different one:
#   VPA_VERSION=vertical-pod-autoscaler-1.3.0 bash solution/install-vpa.sh
# The compatibility table lives at
#   https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler
set -euo pipefail
export MSYS2_ARG_CONV_EXCL='*'

VPA_VERSION=${VPA_VERSION:-vertical-pod-autoscaler-1.2.1}
WORKDIR=${WORKDIR:-"${TMPDIR:-/tmp}/vpa-src"}
ACTION=${1:-install}

fetch() {
  if [ -d "${WORKDIR}/.git" ]; then
    echo "==> reusing ${WORKDIR}"
  else
    echo "==> cloning kubernetes/autoscaler at ${VPA_VERSION} (shallow)"
    rm -rf "${WORKDIR}"
    git clone --depth 1 --branch "${VPA_VERSION}" \
      https://github.com/kubernetes/autoscaler.git "${WORKDIR}"
  fi
}

case "$ACTION" in
  install)
    command -v openssl >/dev/null || { echo "openssl is required (the webhook needs a certificate)"; exit 1; }
    fetch
    echo "==> running hack/vpa-up.sh"
    ( cd "${WORKDIR}/vertical-pod-autoscaler" && ./hack/vpa-up.sh )

    echo "==> waiting for the three components"
    for d in vpa-recommender vpa-updater vpa-admission-controller; do
      kubectl -n kube-system rollout status "deployment/$d" --timeout=180s || true
    done
    kubectl -n kube-system get pods -l 'app in (vpa-recommender,vpa-updater,vpa-admission-controller)'

    echo
    echo "==> the CRD it registered:"
    kubectl get crd | grep -i verticalpodautoscaler
    echo
    echo "==> the mutating webhook it registered (this is how pods get resized):"
    kubectl get mutatingwebhookconfiguration | grep -i vpa || true
    ;;

  uninstall)
    fetch
    ( cd "${WORKDIR}/vertical-pod-autoscaler" && ./hack/vpa-down.sh )
    echo "==> removed. Confirm nothing is left behind:"
    kubectl get mutatingwebhookconfiguration | grep -i vpa || echo "    no VPA webhook"
    kubectl get crd | grep -i verticalpodautoscaler || echo "    no VPA CRD"
    ;;

  *)
    echo "usage: $0 [install|uninstall]"; exit 1 ;;
esac
