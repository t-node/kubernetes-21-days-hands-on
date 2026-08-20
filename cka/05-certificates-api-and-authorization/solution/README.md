# CKA 05 solution

```bash
bash onboard-user.sh akshay developers devboard    # the whole flow, end to end
bash make-hostile-csr.sh                           # the CSR you must deny
```

| File | Purpose |
|---|---|
| `csr-template.yaml` | the object shape, with the `base64 -w 0` warning |
| `onboard-user.sh` | key → CSR → approve → extract → kubeconfig |
| `make-hostile-csr.sh` | a `system:masters` request, for the deny exercise |

## Exam-style task answers

### 1. Create the CSR object (4 min)

```bash
cat > /tmp/exam/john-csr.yaml <<EOF
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: john
spec:
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 3600
  usages:
    - client auth
  request: $(cat /tmp/exam/john.csr | base64 -w 0)
EOF

kubectl apply -f /tmp/exam/john-csr.yaml
kubectl get csr john
```

Three things graders check: `-w 0` on the base64, the exact `signerName`, and
`usages: ["client auth"]`. If it rejects with `illegal base64 data`, your
encoding wrapped.

The heredoc with `$(...)` inline is worth practising — it removes the
copy-paste-into-YAML step that causes most failures here.

### 2. Approve and extract (2 min)

```bash
kubectl certificate approve john
kubectl get csr john                    # Approved,Issued
kubectl get csr john -o jsonpath='{.status.certificate}' | base64 -d > /tmp/exam/john.crt
openssl x509 -in /tmp/exam/john.crt -noout -subject -dates
```

**`Approved,Issued` — both.** `Approved` alone means the controller manager
could not sign; check `--cluster-signing-cert-file` and
`--cluster-signing-key-file`.

### 3. The intruder (3 min)

```bash
kubectl get csr intruder -o jsonpath='{.spec.groups}{"\n"}'
```

If that contains `system:masters`:

```bash
kubectl certificate deny intruder
kubectl get csr intruder                # Denied
kubectl delete csr intruder
```

**Read before acting.** `system:masters` is bound to `cluster-admin` by a
built-in ClusterRoleBinding, so approving it grants the whole cluster —
irreversibly, because there is no CRL. You can deny a Pending request; you
cannot un-approve an approved one.

### 4. Authorization modes, two ways (2 min)

```bash
docker exec devops-control-plane sh -c \
  "grep authorization-mode /etc/kubernetes/manifests/kube-apiserver.yaml"

docker exec devops-control-plane sh -c \
  "ps aux | grep [k]ube-apiserver | xargs -n1 | grep authorization-mode"
```

`--authorization-mode=Node,RBAC`. Know both: the manifest is the declared
configuration, `ps` is what is **actually running** — and they differ when an
edit has not taken effect.

### 5. Grant john read-only and prove it (3 min)

```bash
kubectl create rolebinding john-view --clusterrole=view --user=john -n devboard

kubectl auth can-i list pods    -n devboard --as=john      # yes
kubectl auth can-i get  secrets -n devboard --as=john      # no  -- `view` excludes secrets
kubectl auth can-i delete pods  -n devboard --as=john      # no
```

`--as` is impersonation: you verify his permissions without his credentials.
That is the "prove it without logging in as him" part, and it is faster and
safer than building a kubeconfig.

---

## The seven answers

1. **`/etc/kubernetes/pki/ca.crt` and `ca.key`**, on the control-plane node in a
   kubeadm cluster. Together they *are* the CA — anyone holding them can mint a
   certificate for any identity and any group.

2. **The controller manager**, via its `csrapproving` and `csrsigning`
   controllers, configured by `--cluster-signing-cert-file` and
   `--cluster-signing-key-file`. Not the API server.

3. `base64` wraps at 76 characters by default, and a wrapped value is invalid
   inside a YAML scalar — `illegal base64 data at input byte ...`. `-w 0`
   disables wrapping; on macOS use `base64 | tr -d '\n'`.

4. **The controller manager cannot sign.** `Approved` and `Issued` are separate
   conditions. Check that the two signing flags are present and point at a
   readable CA key.

5. **Node, RBAC, ABAC, Webhook, AlwaysAllow/AlwaysDeny.** If
   `--authorization-mode` is omitted it defaults to **AlwaysAllow** — every
   request permitted with no checks. Check this on any cluster you inherit.

6. **A deny passes the request to the next module; an allow ends the chain
   immediately.** Only when every module has denied do you get `403`. So
   `AlwaysAllow` anywhere in the list makes everything after it irrelevant.

7. **Authentication succeeded, authorization failed.** The certificate is valid
   and the cluster knows the identity — it just has no RBAC binding.
   `Unauthorized` (401) would mean the credential itself was rejected.

---

## Carry this to the exam

**Three reflexes.**

`base64 -w 0`, every time, without thinking about it.

Read `spec.groups` before every approval:

```bash
kubectl get csr NAME -o jsonpath='{.spec.groups}'
```

And when a new identity gets `Forbidden`, stop looking at certificates — that
error means the certificate **worked**. The problem is a missing RoleBinding.

**One habit worth more than all three:** bind to **groups**, not users. Issue
certificates with the right `O`, bind the group once, and every future joiner is
authorised on day one with no new Kubernetes objects at all.
