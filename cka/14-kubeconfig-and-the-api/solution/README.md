# CKA 04 solution

```bash
bash make-multi-config.sh      # /tmp/my-kube-config  -- 4/4/4
bash break-kubeconfig.sh       # /tmp/broken-config   -- bad cert path
```

## Exam-style task answers

### 1. Count clusters, users, contexts (2 min)

```bash
K=/tmp/my-kube-config
kubectl config --kubeconfig=$K view -o jsonpath='{range .clusters[*]}{.name}{"\n"}{end}' | wc -l
kubectl config --kubeconfig=$K view -o jsonpath='{range .users[*]}{.name}{"\n"}{end}'    | wc -l
kubectl config --kubeconfig=$K view -o jsonpath='{range .contexts[*]}{.name}{"\n"}{end}' | wc -l
```

Four each. Faster under pressure:

```bash
kubectl config --kubeconfig=$K get-contexts
```

### 2. Which user and cluster does `research` use? (1 min)

```bash
kubectl config --kubeconfig=$K view \
  -o jsonpath='{range .contexts[?(@.name=="research")]}{.context.user}{" @ "}{.context.cluster}{"\n"}{end}'
# dev-user @ test-cluster-1
```

**The point of the question.** The context is called `research`, which tells you
nothing about the user. Naming conventions like `dev-user@development` are just
conventions — always read `context.user`.

### 3. Switch that file's context without making it your default (2 min)

```bash
kubectl config --kubeconfig=/tmp/my-kube-config use-context research
kubectl config --kubeconfig=/tmp/my-kube-config current-context
grep current-context /tmp/my-kube-config
```

`--kubeconfig` targets that file only; your own `~/.kube/config` is untouched.
Confirm:

```bash
kubectl config current-context        # still kind-devops
```

### 4. Make it the default (2 min)

Two acceptable answers.

Persistent, and what the source lab does:

```bash
cp ~/.kube/config ~/.kube/config.backup
mv /tmp/my-kube-config ~/.kube/config
kubectl config view
```

Session-only, and safer:

```bash
export KUBECONFIG=/tmp/my-kube-config
```

**Say which you chose and why.** Overwriting `~/.kube/config` is irreversible
without the backup — take one first. In an exam, `export` is usually the better
answer unless the task explicitly says "make it the default file".

### 5. Your CN and O (3 min)

```bash
kubectl config view --raw \
  -o jsonpath='{.users[0].user.client-certificate-data}' \
  | base64 -d | openssl x509 -noout -subject
```

```
subject=O = system:masters, CN = kubernetes-admin
```

**`CN` is the username, `O` is a group.** `system:masters` is bound to
`cluster-admin` by a built-in ClusterRoleBinding, which is why you have had
unlimited access all course.

If the kubeconfig used the path form instead:

```bash
openssl x509 -in /path/to/client.crt -noout -subject -issuer -dates
```

### 6. List kube-system pods with curl alone (4 min)

Extract the three files, then call the core-group path:

```bash
kubectl config view --raw -o jsonpath='{.users[0].user.client-certificate-data}'      | base64 -d > /tmp/c.crt
kubectl config view --raw -o jsonpath='{.users[0].user.client-key-data}'              | base64 -d > /tmp/c.key
kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > /tmp/ca.crt
chmod 600 /tmp/c.key
SERVER=$(kubectl config view -o jsonpath='{.clusters[0].cluster.server}')

curl -s --cert /tmp/c.crt --key /tmp/c.key --cacert /tmp/ca.crt \
  "$SERVER/api/v1/namespaces/kube-system/pods" \
  | grep '"name"' | head
```

Pods are **core**, so `/api/v1/...` with no group segment. Much less typing:

```bash
kubectl proxy --port=8001 &
curl -s http://localhost:8001/api/v1/namespaces/kube-system/pods | grep '"name"' | head
kill %1
```

---

## The seven answers

1. **clusters** (where), **users** (who), **contexts** (a named pairing of one
   cluster and one user). `current-context` points at the active pairing.

2. `--kubeconfig` beats `KUBECONFIG` beats `~/.kube/config`. `KUBECONFIG` may be
   a colon-separated list, merged left to right — and writes land in the
   **first** file.

3. `kubectl config view` redacts certificate data to `DATA+OMITTED` so you do
   not paste a private key into a ticket. `--raw` shows it.

4. Pod: `/api/v1/namespaces/<ns>/pods`. Deployment:
   `/apis/apps/v1/namespaces/<ns>/deployments`. Pods are in the original **core**
   group, which predates API grouping and has no group name; Deployments are in
   the named **apps** group.

5. `apiGroups: [""]` **is** the core group — the empty string is its name.
   That is why pods and configmaps use `""` while deployments need `"apps"`,
   and why the wrong group silently grants nothing.

6. **`kube-proxy`** is a cluster component, one per node, programming
   iptables/IPVS so Services work. **`kubectl proxy`** is a local command that
   opens an authenticated HTTP proxy to the API server on :8001. Unrelated
   despite the names.

7. In a client certificate, **`CN` becomes the username** and **each `O`
   becomes a group**. Nothing is "created" — RBAC matches those strings.

---

## Carry this to the exam

**Pin the namespace immediately.** The moment a question names one:

```bash
kubectl config set-context --current --namespace=<ns>
```

Every later command in that question loses its `-n`. Over a three-hour exam that
is real time, and it removes a whole class of "I ran it in the wrong namespace"
mistakes.

**And read the error before touching anything:**

| Error | Fix |
|---|---|
| `connection refused` | the server address |
| `401 Unauthorized` | the certificate |
| `403 Forbidden` | RBAC |
| `no such file or directory` | the certificate path in kubeconfig |
