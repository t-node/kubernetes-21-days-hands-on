# CKA 02 — etcd and Cluster Data

**Time:** 60-75 minutes
**Prerequisites:** [Day 01](../../days/day-01-architecture-and-kind-cluster/), [CKA 01](../02-container-runtimes-and-crictl/)

Day 01 told you etcd holds all cluster state and that backing it up is the
number one operational task. Then it never let you touch it. This day fixes
that: you will read your own cluster's data out of etcd directly.

---

## Part 1 - Concepts

### 2.1 What a key-value store is, and why Kubernetes uses one

Three storage models, and where etcd sits:

**Relational (SQL).** Rows and columns, fixed schema. Add a `salary` column and
*every* row gets it — including the people who have no salary, who now carry an
empty cell. Add `grade` for students and adults carry another empty cell. Strong
querying and joins, rigid structure, best for genuinely uniform data.

**Document store.** One document per entity, typically JSON. Each can have a
different shape: the employee document has `salary`, the student document has
`grade`, and neither pollutes the other. Flexible, weaker at cross-entity
queries.

**Key-value store.** A value against a key, and nothing else:

```
name      -> John
location  -> New York
salary    -> 5000
```

The value can be a scalar or an entire JSON document. No schema, no joins, no
complex queries — and **very fast lookups**.

| | Relational | Document | Key-value |
|---|---|---|---|
| Schema | strict | optional | none |
| Complex queries | yes | limited | **no** |
| Performance | good | good | **fastest** |
| Flexibility | rigid | high | **highest** |
| Best for | structured data | semi-structured | **simple fast lookup** |

Kubernetes wants exactly the last row. It never asks etcd "find all pods with
CPU above 80%" — the API server does that filtering. It asks "give me the object
at this path", millions of times. Key-value is the right shape.

**etcd** adds two things to that model: it is **distributed** (runs as a cluster
across control-plane nodes) and **reliable** (the raft consensus protocol
guarantees agreement on every write).

### 2.2 What etcd holds in Kubernetes

**Everything.** Nodes, pods, deployments, replicasets, configmaps, secrets,
service accounts, roles, role bindings, namespaces — every object you have
created in twenty-one days.

Two consequences that people underrate:

1. **Every `kubectl get` is ultimately an etcd read.** The API server is the
   only component that talks to etcd; everything else goes through it.
2. **A change is not "done" until etcd has it.** Create a pod and the API server
   writes to etcd *before* the scheduler ever sees it. If the etcd write fails,
   nothing happened.

Lose etcd and you have lost the cluster: not the running containers, which
kubelets keep alive from local state, but every object definition and any
ability to reconcile. That is why **etcd backup is the single most important
control-plane task**, and why it is near-certain to appear on the exam.

### 2.3 The `/registry` tree

etcd is flat, but Kubernetes imposes a path convention on the keys:

```
/registry/<resource-type>/<namespace>/<name>
```

Concretely, from a cluster you have built:

```
/registry/namespaces/devboard
/registry/pods/devboard/backend-6c8b9d7f4-2xk9p
/registry/deployments/devboard/backend
/registry/services/specs/devboard/backend
/registry/secrets/devboard/devboard-secrets
/registry/configmaps/devboard/devboard-config
/registry/minions/devops-worker
```

Two things to notice. **`minions`** is the historical name for nodes and is
still the etcd key — a fossil from before "node" was settled on. And **secrets
sit in that tree as ordinary values**, which is the concrete reason Day 10 said
"not encrypted at rest by default": anyone who can read etcd can read every
secret, without touching Kubernetes at all. You will prove that in the lab.

### 2.4 Where etcd runs, and how that changes the commands

Two deployment styles, and you must recognise both:

**kubeadm (your kind cluster, and most real clusters).** etcd runs as a **static
pod** on the control-plane node, from `/etc/kubernetes/manifests/etcd.yaml`. You
see it with `kubectl get pods -n kube-system`, its certificates live in
`/etc/kubernetes/pki/etcd/`, and you run `etcdctl` inside the pod.

**From scratch ("the hard way").** You download the etcd binary and configure it
as a **systemd service** at `/etc/systemd/system/etcd.service`. There is no pod
to exec into; you run `etcdctl` on the host.

The options that matter in either case:

| Option | Meaning |
|---|---|
| `--advertise-client-urls` | the address clients use — normally `https://<node-ip>:2379`. **This is what the API server's `--etcd-servers` must point at** |
| `--listen-client-urls` | what etcd binds locally |
| `--initial-cluster` | for HA: every etcd member, so they can find each other |
| `--data-dir` | where the data actually lives (`/var/lib/etcd`) |
| `--cert-file`, `--key-file`, `--trusted-ca-file` | client TLS |
| `--peer-*` equivalents | member-to-member TLS |

**Ports:** `2379` for clients, `2380` for peer traffic between members.

In an HA cluster you run etcd on each control-plane node and list them all in
`--initial-cluster`. Member count should be **odd** — 3 or 5 — because raft
needs a quorum of `(n/2)+1`, and an even number gives you no extra fault
tolerance for the extra node.

### 2.5 The v2/v3 API split — the most common etcdctl mistake

etcd's API changed incompatibly between major versions, and the command names
changed with it:

| Operation | v2 API | v3 API |
|---|---|---|
| write | `etcdctl set k v` | **`etcdctl put k v`** |
| read | `etcdctl get k` | `etcdctl get k` |
| delete | `etcdctl rm k` | **`etcdctl del k`** |
| transactions | not supported | supported |

**Kubernetes uses the v3 API.** If you follow an old blog using `set` and `rm`
you are on v2 and will not see Kubernetes' data at all — a genuinely confusing
failure, because the commands appear to work against an empty store.

Force it explicitly:

```bash
export ETCDCTL_API=3
etcdctl version                 # check the "API version:" line
```

etcd 3.4 and later default to v3, so you may not need it — but set it anyway
under exam pressure rather than debugging why `get` returns nothing.

> **One more version trap:** in etcd **3.5+**, `snapshot status` and `snapshot
> restore` moved to a separate binary, **`etcdutl`**. `etcdctl snapshot save`
> still works. If `snapshot status` errors or warns as deprecated, reach for
> `etcdutl`.

---

## Part 2 - Hands-on lab

### Step 1: Find etcd in your cluster

```bash
kubectl get pods -n kube-system -l component=etcd
kubectl get pod -n kube-system etcd-devops-control-plane -o jsonpath='{.metadata.ownerReferences[0].kind}{"\n"}'
```

`Node`, not `ReplicaSet` — a **static pod**, started by the kubelet from disk
with no scheduler involved. Read the manifest that defines it:

```bash
docker exec devops-control-plane cat /etc/kubernetes/manifests/etcd.yaml
```

Pull out the options from section 2.4:

```bash
docker exec devops-control-plane sh -c \
  "grep -E 'advertise-client-urls|listen-client-urls|data-dir|initial-cluster|cert-file' /etc/kubernetes/manifests/etcd.yaml"
```

Now confirm the API server points at exactly that address:

```bash
docker exec devops-control-plane sh -c \
  "grep -E 'etcd-servers|etcd-cafile|etcd-certfile' /etc/kubernetes/manifests/kube-apiserver.yaml"
```

`--etcd-servers=https://127.0.0.1:2379` on the API server matches
`--advertise-client-urls` on etcd. **Break that correspondence and the entire
cluster stops** — a favourite exam scenario.

### Step 2: Set up etcdctl

Everything below needs endpoint plus three certificate flags. Save the typing:

```bash
ETCD="kubectl -n kube-system exec etcd-devops-control-plane -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key"

$ETCD version
$ETCD endpoint health
$ETCD endpoint status --write-out=table
$ETCD member list --write-out=table
```

Check the `API version:` line reads **3.x**. If a command hangs or reports a
certificate error, the paths are wrong — confirm them against
`/etc/kubernetes/manifests/etcd.yaml`, since that file is the source of truth.

> **On the exam** those flags are given to you in the task text. Do not memorise
> the paths; memorise that **four flags are always required**: `--endpoints`,
> `--cacert`, `--cert`, `--key`.

### Step 3: Read your own cluster out of etcd

```bash
$ETCD get / --prefix --keys-only | head -30
$ETCD get / --prefix --keys-only | wc -l
```

Every object in your cluster. Narrow it down:

```bash
$ETCD get /registry --prefix --keys-only | sed 's|/registry/||' | cut -d/ -f1 | sort | uniq -c | sort -rn | head -20
```

A census of your cluster by resource type, straight from the database. Then the
tree from section 2.3:

```bash
$ETCD get /registry/pods/devboard --prefix --keys-only
$ETCD get /registry/deployments/devboard --prefix --keys-only
$ETCD get /registry/namespaces --prefix --keys-only
$ETCD get /registry/minions --prefix --keys-only        # nodes, historically named
```

Now read one object's actual value:

```bash
$ETCD get /registry/namespaces/devboard
```

Mostly binary — Kubernetes stores objects **protobuf-encoded**, not as JSON, for
size and speed. You can still see readable fragments. That is why you use
`kubectl` to read objects and etcd only to understand what exists.

### Step 4: Prove secrets are not encrypted at rest

Day 10 claimed anyone with etcd access reads every secret. Prove it:

```bash
$ETCD get /registry/secrets/devboard/devboard-secrets | strings | grep -A2 -i "POSTGRES_PASSWORD"
```

Or more bluntly:

```bash
$ETCD get /registry/secrets/devboard/devboard-secrets | strings | grep -i devboard
```

**Your database password, in plaintext, in the datastore.** No base64, no
Kubernetes API, no RBAC in the way — just bytes on disk.

This is the concrete argument for:

- **`EncryptionConfiguration`** on the API server, ideally with a KMS provider,
  so values are encrypted before they reach etcd
- restricting who can reach etcd's port and read `/var/lib/etcd` at all
- **not putting static credentials in Kubernetes** where a cloud identity would
  do (Day 10, section 10.3)

Anyone who says "Kubernetes Secrets are encrypted" can be shown this command.

### Step 5: Write directly to etcd, and see why you should not

```bash
$ETCD put /demo/hello "world"
$ETCD get /demo/hello
$ETCD del /demo/hello
```

Fine — that key is outside `/registry`, so Kubernetes ignores it. Now consider
what writing *inside* `/registry` would mean: you would bypass the API server
entirely, and with it validation, admission control, RBAC and every controller's
notion of what changed. The object would be malformed protobuf or silently
inconsistent, and the resulting failure would be extremely hard to diagnose.

**Read from etcd freely. Never write to `/registry`.** Every legitimate change
goes through the API server.

### Step 6: Watch etcd change as you use kubectl

Terminal 1:

```bash
kubectl -n kube-system exec etcd-devops-control-plane -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  watch /registry/namespaces --prefix
```

Terminal 2:

```bash
kubectl create namespace etcd-demo
kubectl delete namespace etcd-demo
```

Terminal 1 prints the PUT and DELETE as they happen. You are watching the
Kubernetes control plane write to its database in real time — `kubectl` at one
end, raw storage at the other, and nothing in between but the API server.

Ctrl-C to stop.

### Step 7: The data directory

```bash
docker exec devops-control-plane ls -la /var/lib/etcd/member/
docker exec devops-control-plane du -sh /var/lib/etcd/
$ETCD endpoint status --write-out=table
```

`wal/` is the write-ahead log, `snap/` holds snapshots. The `DB SIZE` column is
what you monitor: etcd defaults to a **2 GB quota**, and exceeding it puts the
cluster into a read-only alarm state that requires compaction and defragmenting
to clear. A cluster that suddenly refuses all writes with `mvcc: database space
exceeded` is this.

> **Backup and restore** — `etcdctl snapshot save` / `restore` — is the task the
> exam is most likely to set. Its lecture was not in the transcript I received,
> so this day deliberately stops short rather than guessing at the course's
> treatment. Send that section and it gets built.

---

## Validate

```bash
ETCD="kubectl -n kube-system exec etcd-devops-control-plane -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key"

$ETCD endpoint health                                   # healthy
$ETCD version | grep -i "api version"                   # 3.x
$ETCD get /registry --prefix --keys-only | wc -l        # hundreds
$ETCD get /registry/namespaces --prefix --keys-only | grep devboard
```

You are done when you can answer without looking:

1. Why does Kubernetes use a key-value store rather than SQL?
2. What is the key path for a pod named `web` in namespace `prod`?
3. Which component is the only one that talks to etcd, and why does that matter?
4. What is the difference between `--advertise-client-urls` and
   `--listen-client-urls`, and which must the API server match?
5. Why is `etcdctl set` the wrong command?
6. Are Secrets encrypted in etcd?

---

## Break it

**A. Point the API server at the wrong etcd address.**

The most instructive control-plane failure there is.

```bash
docker exec devops-control-plane sh -c \
  "sed -i 's|--etcd-servers=https://127.0.0.1:2379|--etcd-servers=https://127.0.0.1:9999|' \
   /etc/kubernetes/manifests/kube-apiserver.yaml"

sleep 45
kubectl get nodes
```

```
The connection to the server 127.0.0.1:6443 was refused
```

**The entire cluster is unreachable.** No `kubectl` at all — you cannot even
inspect the damage through the API, because the API server is the damage.

This is where CKA 01 pays off. Diagnose it from the node:

```bash
docker exec devops-control-plane sh -c '
  crictl ps -a --name kube-apiserver
  CID=$(crictl ps -a --name kube-apiserver -q | head -1)
  crictl logs "$CID" 2>&1 | tail -5
'
```

The logs name the connection failure to `127.0.0.1:9999`. Fix it:

```bash
docker exec devops-control-plane sh -c \
  "sed -i 's|--etcd-servers=https://127.0.0.1:9999|--etcd-servers=https://127.0.0.1:2379|' \
   /etc/kubernetes/manifests/kube-apiserver.yaml"

sleep 45
kubectl get nodes
```

Note there is no `systemctl restart` and no `kubectl apply`. **The kubelet
watches `/etc/kubernetes/manifests/` and reacts to the file changing** — that is
the entire mechanism for repairing static pods, and it is how nearly every
control-plane repair task on the exam is done.

**B. Use the v2 commands.**

```bash
kubectl -n kube-system exec etcd-devops-control-plane -- sh -c \
  "ETCDCTL_API=2 etcdctl --endpoints=https://127.0.0.1:2379 ls /registry" 2>&1 | tail -3
```

Errors, or an empty result — v2 cannot see data written through the v3 API.
The commands look plausible, which is what makes this waste time. Always confirm
with `etcdctl version`.

**C. Omit the certificate flags.**

```bash
kubectl -n kube-system exec etcd-devops-control-plane -- \
  etcdctl --endpoints=https://127.0.0.1:2379 get /registry --prefix --keys-only 2>&1 | tail -3
```

A TLS error. etcd requires client certificates; there is no anonymous access.
The fix is always the same three flags: `--cacert`, `--cert`, `--key`.

**D. Read a secret you have no RBAC permission for.**

```bash
SA=system:serviceaccount:devboard:devboard-operator
kubectl auth can-i get secrets -n devboard --as=$SA          # no
```

RBAC correctly denies it. But **anyone with node access or etcd credentials
bypasses RBAC entirely** — as Step 4 demonstrated. RBAC protects the API, not
the datastore. Both need securing.

---

## Exam-style tasks

Timed. No looking anything up first.

1. Report the etcd version and the API version this cluster's etcd serves.
   *(2 min)*
2. Count how many pods exist across all namespaces, using **only** `etcdctl` —
   `kubectl` is off limits. *(3 min)*
3. Identify the data directory, the client URL and the peer URL of the etcd
   member, from the node. *(3 min)*
4. The API server will not start. Determine from node-level tools alone whether
   the cause is etcd connectivity. *(5 min)*
5. Is this a single-member or multi-member etcd cluster? How many members would
   you want for HA, and why that number? *(2 min)*

Answers in [`solution/`](solution/).

---

## Cheat card

```bash
# the four flags are ALWAYS required
export ETCDCTL_API=3
etcdctl --endpoints=https://127.0.0.1:2379 \
        --cacert=/etc/kubernetes/pki/etcd/ca.crt \
        --cert=/etc/kubernetes/pki/etcd/server.crt \
        --key=/etc/kubernetes/pki/etcd/server.key \
        <command>

# health and membership
etcdctl endpoint health
etcdctl endpoint status --write-out=table       # DB SIZE lives here
etcdctl member list --write-out=table

# reading cluster data
etcdctl get / --prefix --keys-only
etcdctl get /registry --prefix --keys-only
etcdctl get /registry/pods/<ns> --prefix --keys-only
etcdctl get /registry/namespaces/<name>
etcdctl watch /registry/namespaces --prefix

# generic key-value  (v3 verbs -- NOT set/rm)
etcdctl put  <key> <value>
etcdctl get  <key>
etcdctl del  <key>

# where the config lives
/etc/kubernetes/manifests/etcd.yaml            # kubeadm: static pod
/etc/systemd/system/etcd.service               # from scratch: systemd
/etc/kubernetes/pki/etcd/                      # certificates
/var/lib/etcd/                                 # the data
```

| Thing | Value |
|---|---|
| client port | **2379** |
| peer port | **2380** |
| key prefix | `/registry/<type>/<namespace>/<name>` |
| nodes are stored as | `/registry/minions/...` |
| object encoding | protobuf, not JSON |
| HA member count | **odd** — 3 or 5. Quorum is `(n/2)+1` |
| only component that talks to etcd | **kube-apiserver** |

---

**Back to the [CKA track](../) · [Main course](../../README.md)**
