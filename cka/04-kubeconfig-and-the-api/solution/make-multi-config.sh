#!/usr/bin/env bash
# Build /tmp/my-kube-config -- a multi-cluster kubeconfig of the shape you are
# handed on the exam: several clusters, several users, several contexts, and a
# current-context that is NOT the one you want.
#
# Nothing here connects to a real cluster; the point is reading and switching.
set -euo pipefail

mkdir -p /tmp/fake-pki/users
for u in dev-user test-user aws-user prod-user; do
  : > "/tmp/fake-pki/users/${u}.crt"
  : > "/tmp/fake-pki/users/${u}.key"
done
: > /tmp/fake-pki/ca.crt

cat > /tmp/my-kube-config <<'EOF'
apiVersion: v1
kind: Config
current-context: test-user@development

clusters:
  - name: production
    cluster:
      server: https://production.example.com:6443
      certificate-authority: /tmp/fake-pki/ca.crt
  - name: development
    cluster:
      server: https://development.example.com:6443
      certificate-authority: /tmp/fake-pki/ca.crt
  - name: kubernetes-on-aws
    cluster:
      server: https://aws.example.com:6443
      certificate-authority: /tmp/fake-pki/ca.crt
  - name: test-cluster-1
    cluster:
      server: https://test.example.com:6443
      certificate-authority: /tmp/fake-pki/ca.crt

users:
  - name: dev-user
    user:
      client-certificate: /tmp/fake-pki/users/dev-user.crt
      client-key: /tmp/fake-pki/users/dev-user.key
  - name: test-user
    user:
      client-certificate: /tmp/fake-pki/users/test-user.crt
      client-key: /tmp/fake-pki/users/test-user.key
  - name: aws-user
    user:
      client-certificate: /tmp/fake-pki/users/aws-user.crt
      client-key: /tmp/fake-pki/users/aws-user.key
  - name: prod-user
    user:
      client-certificate: /tmp/fake-pki/users/prod-user.crt
      client-key: /tmp/fake-pki/users/prod-user.key

contexts:
  # NOTE: the context NAME does not have to describe the user it uses.
  # `research` runs as dev-user against test-cluster-1. Read context.user,
  # never the name -- that is the exam trick.
  - name: research
    context:
      cluster: test-cluster-1
      user: dev-user
  - name: test-user@development
    context:
      cluster: development
      user: test-user
  - name: aws-user@kubernetes-on-aws
    context:
      cluster: kubernetes-on-aws
      user: aws-user
  - name: prod-user@production
    context:
      cluster: production
      user: prod-user
      namespace: production-apps
EOF

echo "wrote /tmp/my-kube-config"
echo "  4 clusters, 4 users, 4 contexts, current-context = test-user@development"
echo
echo "Try:"
echo "  kubectl config --kubeconfig=/tmp/my-kube-config get-contexts"
