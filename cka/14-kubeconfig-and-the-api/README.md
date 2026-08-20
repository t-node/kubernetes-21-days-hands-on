# CKA 04 — KubeConfig and the Kubernetes API

**Time:** 60-75 minutes
**Prerequisites:** [Day 01](../../days/day-01-architecture-and-kind-cluster/), [CKA 02](../03-etcd-and-cluster-data/)

Day 01 showed you `kubectl config current-context` and moved on. That is not
enough: on the exam you will be handed a kubeconfig with four clusters, told to
use a specific one, and given a broken certificate path to repair.

This day also opens up the API itself — the paths `kubectl` is actually calling,
and how to call them without `kubectl` at all.

---

## Part 1 - Concepts

### 4.1 What kubeconfig replaces

Strip `kubectl` away and talking to the cluster looks like this:

```bash
curl https://my-cluster:6443/api/v1/pods \
  --key      admin.key \
  --cert     admin.crt \
  --cacert   ca.crt
```

Server address, client certificate, client key, CA certificate. Four values on
every single call. `kubectl` accepts them as flags:

```bash
kubectl get pods \
  --server=https://my-cluster:6443 \
  --client-key=admin.key \
  --client-certificate=admin.crt \
  --certificate-authority=ca.crt
```

Nobody types that twice. **kubeconfig is a file that holds those values so you
do not have to.** That is all it is.

Default location: `$HOME/.kube/config`. Because it is found automatically, you
have gone twenty-one days without passing a single connection flag.

### 4.2 Three sections, and how they join up

```yaml
apiVersion: v1
kind: Config
current-context: dev-user@google

clusters:                      # WHERE  -- the clusters you can reach
  - name: my-kube-playground
    cluster:
      server: https://172.17.0.51:6443
      certificate-authority: /etc/kubernetes/pki/ca.crt

users:                         # WHO    -- the identities you hold
  - name: my-kube-admin
    user:
      client-certificate: /etc/kubernetes/pki/users/admin.crt
      client-key:         /etc/kubernetes/pki/users/admin.key

contexts:                      # WHICH  -- pair a user with a cluster
  - name: my-kube-admin@my-kube-playground
    context:
      cluster: my-kube-playground
      user:    my-kube-admin
      namespace: devboard      # optional, and very useful
```

Read it as three lists and a pointer:

- **clusters** — *where* to connect
- **users** — *who* you are
- **contexts** — a named pairing of one cluster and one user
- **current-context** — which pairing is active right now

> **Nothing here creates anything.** kubeconfig does not create users, grant
> permissions or configure the cluster. It records credentials that already
> exist and says which to use. A user with no RBAC binding is still denied
> everything — kubeconfig gets you *authenticated*, not *authorised*.

**The context name is arbitrary.** `kubernetes-admin@kubernetes` is a
convention, not a rule; the real user is whatever `context.user` says. The
transcript's lab makes exactly this point, and it is a favourite exam trick:
read the field, not the name.

### 4.3 Certificates: path or embedded data

Every certificate field has two spellings:

| By path | Embedded |
|---|---|
| `certificate-authority: /path/ca.crt` | `certificate-authority-data: <base64>` |
| `client-certificate: /path/admin.crt` | `client-certificate-data: <base64>` |
| `client-key: /path/admin.key` | `client-key-data: <base64>` |

The `-data` forms hold the **base64-encoded contents of the file itself**, which
makes the kubeconfig self-contained and portable — no separate files to ship.
kind and most cloud providers generate this form.

To read one:

```bash
kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d
```

**`--raw` is mandatory.** Without it `kubectl` prints `DATA+OMITTED` and you
will think the field is empty.

Use **absolute paths** in the path form. A relative path is resolved against
your current working directory, so the same kubeconfig works from one directory
and fails from another — a genuinely nasty bug.

### 4.4 Selecting a kubeconfig

Three ways, in order of precedence:

```bash
kubectl get pods --kubeconfig /root/my-kube-config     # 1. the flag wins
export KUBECONFIG=/root/my-kube-config                 # 2. the env var
                                                       # 3. ~/.kube/config
```

`KUBECONFIG` also accepts a **list**, merged left to right:

```bash
export KUBECONFIG=~/.kube/config:~/.kube/prod-config
kubectl config get-contexts        # contexts from BOTH files
```

Useful, and a trap: `kubectl config use-context` then writes to the *first*
file in the list, which may not be the one you meant.

### 4.5 The commands

```bash
kubectl config view                          # the effective config, redacted
kubectl config view --raw                    # ...including certificate data
kubectl config view --minify                 # only the current context
kubectl config get-contexts                  # table, * marks current
kubectl config current-context

kubectl config use-context prod-admin@prod   # switch
kubectl config set-context --current --namespace=devboard    # pin a namespace

kubectl config set-cluster     dev --server=https://1.2.3.4:6443
kubectl config set-credentials dev-user --client-key=k.key --client-certificate=c.crt
kubectl config set-context     dev-user@dev --cluster=dev --user=dev-user
kubectl config delete-context  old@old
```

`use-context` and `set-context` **write to the file**. They are not
session-local, which surprises people the first time a teammate's context
changes under them.

That `--namespace` line is worth the price of admission: pin it once and every
subsequent command targets it, no `-n` required.

### 4.6 The API underneath

Everything `kubectl` does is HTTP against paths in two shapes:

| Group | Path | Holds |
|---|---|---|
| **core** (legacy) | `/api/v1/...` | pods, services, namespaces, nodes, configmaps, secrets, PVs, PVCs, endpoints |
| **named** | `/apis/<group>/<version>/...` | everything else |

```
/api/v1/namespaces/devboard/pods
/apis/apps/v1/namespaces/devboard/deployments
/apis/rbac.authorization.k8s.io/v1/namespaces/devboard/roles
/apis/networking.k8s.io/v1/namespaces/devboard/ingresses
```

**This is why RBAC rules say `apiGroups: [""]`.** The empty string *is* the core
group — it has no name because it predates the grouping scheme. Everything new
goes into a named group, which is why `deployments` needs `apiGroups: ["apps"]`
and why getting that wrong silently grants nothing (Day 19, Break It C).

Each resource carries **verbs**: `get`, `list`, `watch`, `create`, `update`,
`patch`, `delete`, `deletecollection`. Those are exactly the verbs you write in
a Role.

### 4.7 `kubectl proxy` is not `kube-proxy`

Two very differently-named-but-similar things:

| | **`kube-proxy`** | **`kubectl proxy`** |
|---|---|---|
| What | a cluster component, one per node | a local command you run |
| Does | programs iptables/IPVS so Services work | opens an HTTP proxy on **:8001** to the API server |
| Auth | n/a | reuses your kubeconfig credentials |
| Lives | in the cluster, always | your terminal, until Ctrl-C |

```bash
kubectl proxy &
curl http://localhost:8001/api/v1/namespaces/devboard/pods
```

No certificates in the command — the proxy attaches them from your kubeconfig.
It is the easy way to explore the API by hand.

---

## Part 2 - Hands-on lab

### Step 1: Dissect your own kubeconfig

```bash
echo $HOME
ls -la ~/.kube/
kubectl config view
```

Count each section the way an exam question would ask:

```bash
kubectl config view -o jsonpath='{range .clusters[*]}{.name}{"\n"}{end}' | wc -l
kubectl config view -o jsonpath='{range .users[*]}{.name}{"\n"}{end}'    | wc -l
kubectl config view -o jsonpath='{range .contexts[*]}{.name}{"\n"}{end}' | wc -l
kubectl config current-context
```

Now the trap from section 4.2 — the context *name* versus the user it actually
uses:

```bash
kubectl config view -o jsonpath='{.contexts[0].name}{"  -> user: "}{.contexts[0].context.user}{"\n"}'
```

`kind-devops` names a context; `kind-devops` also happens to be the user. Do not
assume that. **Read `context.user`.**

### Step 2: Embedded certificate data

kind writes the `-data` form, so there are no `.crt` files to look at:

```bash
kubectl config view | grep -E "certificate|server"
```

`DATA+OMITTED`. Now with `--raw`:

```bash
kubectl config view --raw | grep -E "certificate-authority-data" | head -c 120; echo
```

Decode the CA and read it as a certificate:

```bash
kubectl config view --raw \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > /tmp/ca.crt
openssl x509 -in /tmp/ca.crt -noout -subject -issuer -dates
```

`Subject` and `Issuer` are identical — it is self-signed, because it *is* the
cluster's root CA. Now your own client certificate:

```bash
kubectl config view --raw \
  -o jsonpath='{.users[0].user.client-certificate-data}' | base64 -d > /tmp/client.crt
openssl x509 -in /tmp/client.crt -noout -subject -dates
```

```
subject=O = system:masters, CN = kubernetes-admin
```

**There is your identity, and it explains twenty-one days of unrestricted
access.** `CN` becomes the *username*, each `O` becomes a *group*, and
`system:masters` is bound to `cluster-admin` by default. Day 19 said users are
strings asserted by the authenticator — this is that string.

### Step 3: Call the API without kubectl

You now have the three files. Extract the key too and go direct:

```bash
kubectl config view --raw \
  -o jsonpath='{.users[0].user.client-key-data}' | base64 -d > /tmp/client.key
chmod 600 /tmp/client.key
SERVER=$(kubectl config view -o jsonpath='{.clusters[0].cluster.server}')
echo "$SERVER"

curl -s --cert /tmp/client.crt --key /tmp/client.key --cacert /tmp/ca.crt \
  "$SERVER/api/v1/namespaces/devboard/pods" | head -20
```

That is exactly what `kubectl get pods -n devboard` does. Explore the shapes
from section 4.6:

```bash
C="--cert /tmp/client.crt --key /tmp/client.key --cacert /tmp/ca.crt"

curl -s $C "$SERVER/version"
curl -s $C "$SERVER/api"                                    # core group versions
curl -s $C "$SERVER/apis" | head -40                        # every named group
curl -s $C "$SERVER/apis/apps/v1/namespaces/devboard/deployments" | head -5
```

Now prove authentication is real:

```bash
curl -s --cacert /tmp/ca.crt "$SERVER/api/v1/namespaces/devboard/pods" | head -12
```

`Unauthorized` — the CA proves *the server* to you; the client cert proves *you*
to the server. Both directions are required.

### Step 4: kubectl proxy

```bash
kubectl proxy --port=8001 &
sleep 2

curl -s http://localhost:8001/version
curl -s http://localhost:8001/apis | head -20
curl -s http://localhost:8001/api/v1/namespaces/devboard/pods | head -10
```

No certificates anywhere — the proxy attaches them from your kubeconfig. This is
the practical way to browse the API.

```bash
kill %1
```

### Step 5: Build a multi-cluster kubeconfig

```bash
kubectl apply -f ../../days/day-19-rbac/solution/01-serviceaccounts.yaml 2>/dev/null || true
bash solution/make-multi-config.sh
```

That writes `/tmp/my-kube-config` with several clusters, users and contexts —
the shape you are handed on the exam.

```bash
export KUBECONFIG=/tmp/my-kube-config
kubectl config get-contexts
kubectl config view -o jsonpath='{range .contexts[*]}{.name}{" -> "}{.context.user}{"\n"}{end}'
kubectl config current-context
```

Switch context **in that file specifically**:

```bash
kubectl config --kubeconfig=/tmp/my-kube-config use-context research
kubectl config --kubeconfig=/tmp/my-kube-config current-context
grep current-context /tmp/my-kube-config
```

The change was **written to the file**, not held in your shell.

```bash
unset KUBECONFIG
kubectl config current-context          # back to kind-devops
```

### Step 6: Pin a namespace to a context

```bash
kubectl config set-context --current --namespace=devboard
kubectl config view --minify | grep namespace
kubectl get pods                        # no -n needed
kubectl config set-context --current --namespace=default
```

On the exam this saves a flag on every command. Set it the moment a question
names a namespace.

### Step 7: Break a certificate path and fix it

The transcript's lab, and a realistic failure:

```bash
bash solution/break-kubeconfig.sh
export KUBECONFIG=/tmp/broken-config
kubectl get nodes
```

```
error: unable to read client-cert /etc/kubernetes/pki/users/developer-user.crt
for dev-user due to open ...: no such file or directory
```

**The error names the exact path.** Find what is actually there:

```bash
ls /tmp/fake-pki/users/
```

`dev-user.crt`, not `developer-user.crt`. Fix it:

```bash
sed -i 's|developer-user.crt|dev-user.crt|' /tmp/broken-config
kubectl config view --minify | grep client-certificate
unset KUBECONFIG
```

Read the whole error before touching anything: it gave you the field, the path
and the user.

---

## Validate

```bash
kubectl config current-context
kubectl config view --raw -o jsonpath='{.users[0].user.client-certificate-data}' \
  | base64 -d | openssl x509 -noout -subject
# subject=O = system:masters, CN = kubernetes-admin

kubectl proxy --port=8001 & sleep 2
curl -s http://localhost:8001/api/v1/namespaces/devboard/pods -o /dev/null -w "%{http_code}\n"
kill %1
```

You are done when you can answer, without looking:

1. Name the three sections of a kubeconfig and what joins them.
2. What is the precedence between `--kubeconfig`, `KUBECONFIG` and the default?
3. Why does `kubectl config view` print `DATA+OMITTED`, and how do you see it?
4. What is the API path for a Deployment? For a Pod? Why do they differ?
5. What does `apiGroups: [""]` mean in an RBAC rule?
6. `kubectl proxy` vs `kube-proxy`?
7. Where does `CN` in a client certificate end up? Where does `O`?

---

## Break it

**A. Point at a server that is not there.**

```bash
kubectl config set-cluster kind-devops --server=https://127.0.0.1:9999
kubectl get nodes
kubectl config set-cluster kind-devops \
  --server="$(kubectl config view -o jsonpath='{.clusters[0].cluster.server}')" 2>/dev/null
```

`connection refused`. Distinguish it from `Unauthorized` (bad credentials) and
`Forbidden` (good credentials, no RBAC). **Three different errors, three
different fixes** — and confusing them wastes real exam minutes.

Restore properly if the above did not:

```bash
kind export kubeconfig --name devops
kubectl get nodes
```

**B. Use a relative certificate path.**

```bash
cp ~/.kube/config /tmp/rel-config
python - <<'PY'
import io
p="/tmp/rel-config"; s=io.open(p,encoding="utf-8").read()
s=s.replace("certificate-authority-data:","certificate-authority: ca.crt\n    x-unused:")
io.open(p,"w",encoding="utf-8").write(s)
PY
KUBECONFIG=/tmp/rel-config kubectl get nodes 2>&1 | head -2
cd /tmp && KUBECONFIG=/tmp/rel-config kubectl get nodes 2>&1 | head -2; cd - >/dev/null
```

The same file behaves differently depending on your working directory. **Always
use absolute paths**, or the `-data` form.

**C. Merge two kubeconfigs and watch a write land in the wrong file.**

```bash
cp ~/.kube/config /tmp/a-config
bash solution/make-multi-config.sh >/dev/null
export KUBECONFIG=/tmp/a-config:/tmp/my-kube-config
kubectl config get-contexts | wc -l          # contexts from BOTH

kubectl config use-context research
grep -c "current-context: research" /tmp/a-config /tmp/my-kube-config
unset KUBECONFIG
```

The write went to `/tmp/a-config` — the **first** file in the list — not the one
that owns the context. Merging is convenient and this is its sharp edge.

**D. `Unauthorized` vs `Forbidden`.**

```bash
SERVER=$(kubectl config view -o jsonpath='{.clusters[0].cluster.server}')
curl -s --cacert /tmp/ca.crt "$SERVER/api/v1/pods" | head -5      # 401 Unauthorized

kubectl auth can-i list pods -n devboard \
  --as=system:serviceaccount:devboard:devboard-intern              # no -> 403 territory
```

**401 = I do not know who you are** (authentication — fix the certificate).
**403 = I know who you are and you may not** (authorization — fix RBAC).

---

## Exam-style tasks

Timed.

1. A kubeconfig is at `/tmp/my-kube-config`. How many clusters, users and
   contexts does it define? *(2 min)*
2. Which user does its `research` context use, and against which cluster?
   *(1 min)*
3. Set that file's current context to `research` **without** making it your
   default kubeconfig. *(2 min)*
4. Make `/tmp/my-kube-config` the default kubeconfig for all future commands.
   *(2 min)*
5. Extract your own client certificate and report its CN and O values.
   *(3 min)*
6. Using `curl` alone, list every pod in `kube-system`. *(4 min)*

Answers in [`solution/`](solution/).

---

## Cheat card

```bash
kubectl config view                         # redacted
kubectl config view --raw                   # with certificate data
kubectl config view --minify                # current context only
kubectl config get-contexts                 # table, * = current
kubectl config current-context

kubectl config use-context NAME
kubectl config --kubeconfig=/path use-context NAME     # operate on ANOTHER file
kubectl config set-context --current --namespace=devboard

kubectl get pods --kubeconfig /path         # 1. highest precedence
export KUBECONFIG=/path                     # 2.
#                                             3. ~/.kube/config

# decode embedded certs  (--raw is MANDATORY)
kubectl config view --raw -o jsonpath='{.users[0].user.client-certificate-data}' \
  | base64 -d | openssl x509 -noout -subject -dates

# raw API
kubectl proxy --port=8001 &
curl http://localhost:8001/api/v1/namespaces/devboard/pods
curl -s --cert c.crt --key c.key --cacert ca.crt https://SERVER:6443/apis
```

| Path | Group |
|---|---|
| `/api/v1/...` | **core** — pods, services, namespaces, nodes, configmaps, secrets |
| `/apis/apps/v1/...` | Deployments, ReplicaSets, StatefulSets, DaemonSets |
| `/apis/rbac.authorization.k8s.io/v1/...` | Roles, RoleBindings |
| `/apis/networking.k8s.io/v1/...` | Ingress, NetworkPolicy |

| Error | Layer | Fix |
|---|---|---|
| `connection refused` | network / wrong server | the cluster address |
| `401 Unauthorized` | **authentication** | certificate or token |
| `403 Forbidden` | **authorization** | RBAC |
| `no such file or directory` | kubeconfig | the certificate path |

**Certificate → identity:** `CN` becomes the **user**, each `O` becomes a
**group**.

---

**Next: [CKA 05 — Certificates API and authorization modes](../15-certificates-api-and-authorization/)**
