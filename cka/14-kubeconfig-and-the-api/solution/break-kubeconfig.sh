#!/usr/bin/env bash
# Produce /tmp/broken-config -- a kubeconfig whose client certificate path is
# wrong, reproducing the failure from the source lab.
#
#   export KUBECONFIG=/tmp/broken-config
#   kubectl get nodes
#   -> unable to read client-cert .../developer-user.crt ... no such file
#
# The file on disk is dev-user.crt. Read the error, compare with `ls`, fix.
set -euo pipefail

mkdir -p /tmp/fake-pki/users
: > /tmp/fake-pki/users/dev-user.crt        # the file that DOES exist
: > /tmp/fake-pki/users/dev-user.key
: > /tmp/fake-pki/ca.crt

cat > /tmp/broken-config <<'EOF'
apiVersion: v1
kind: Config
current-context: research

clusters:
  - name: test-cluster-1
    cluster:
      server: https://127.0.0.1:6443
      certificate-authority: /tmp/fake-pki/ca.crt

users:
  - name: dev-user
    user:
      # WRONG on purpose: the file is dev-user.crt
      client-certificate: /etc/kubernetes/pki/users/developer-user.crt
      client-key: /tmp/fake-pki/users/dev-user.key

contexts:
  - name: research
    context:
      cluster: test-cluster-1
      user: dev-user
EOF

echo "wrote /tmp/broken-config"
echo
echo "  export KUBECONFIG=/tmp/broken-config"
echo "  kubectl get nodes          # read the error, then: ls /tmp/fake-pki/users/"
