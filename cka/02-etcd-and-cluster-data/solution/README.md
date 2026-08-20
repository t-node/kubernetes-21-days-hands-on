# CKA 02 solution

Set this up first — every answer assumes it:

```bash
ETCD="kubectl -n kube-system exec etcd-devops-control-plane -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key"
```

## Exam-style task answers

### 1. etcd version and API version (2 min)

```bash
$ETCD version
```

Two lines: `etcdctl version` (the client) and `API version` (the protocol).
The API version must read **3.x** — Kubernetes uses the v3 API.

Cross-check the server-side image, which is the version that actually matters:

```bash
kubectl get pod -n kube-system etcd-devops-control-plane \
  -o jsonpath='{.spec.containers[0].image}{"\n"}'
```

### 2. Count all pods using only etcdctl (3 min)

```bash
$ETCD get /registry/pods --prefix --keys-only | grep -c registry
```

`--keys-only` output includes blank separator lines, so a bare `wc -l`
overcounts — `grep -c registry` counts real keys. Per namespace:

```bash
$ETCD get /registry/pods --prefix --keys-only \
  | grep registry | cut -d/ -f4 | sort | uniq -c
```

Verify against the API (allowed *after* answering):

```bash
kubectl get pods -A --no-headers | wc -l
```

They should match. If etcd shows more, you are seeing objects mid-deletion.

### 3. Data dir, client URL, peer URL (3 min)

```bash
docker exec devops-control-plane sh -c \
  "grep -E 'data-dir|advertise-client-urls|listen-client-urls|listen-peer-urls|initial-advertise-peer-urls' \
   /etc/kubernetes/manifests/etcd.yaml"
```

Expect `--data-dir=/var/lib/etcd`, client URLs on **2379**, peer URLs on
**2380**.

Also obtainable from etcd itself:

```bash
$ETCD member list --write-out=table
```

The table shows each member's peer and client URLs.

**The distinction the task is testing:** `--listen-client-urls` is what etcd
binds locally; `--advertise-client-urls` is the address it tells clients to use
and is what `--etcd-servers` on the API server must match. On a single-node
cluster they look the same, which is why people conflate them — on a real
multi-node cluster they differ and getting it wrong breaks the control plane.

### 4. Is the API server failing because of etcd? (5 min)

`kubectl` is unavailable, so work from the node:

```bash
# 1. is the container even running?
docker exec devops-control-plane crictl ps -a --name kube-apiserver

# 2. what does it say?
docker exec devops-control-plane sh -c '
  CID=$(crictl ps -a --name kube-apiserver -q | head -1)
  crictl logs "$CID" 2>&1 | tail -20
'

# 3. is etcd itself up?
docker exec devops-control-plane crictl ps --name etcd
docker exec devops-control-plane sh -c '
  CID=$(crictl ps -a --name etcd -q | head -1)
  crictl logs "$CID" 2>&1 | tail -10
'

# 4. what address is the API server configured to use?
docker exec devops-control-plane sh -c \
  "grep etcd-servers /etc/kubernetes/manifests/kube-apiserver.yaml"
```

**Distinguishing the two cases:**

- API server logs show connection refused or a timeout to an etcd address, while
  the etcd container is healthy → **the address is wrong**. Fix
  `--etcd-servers` in the manifest.
- The etcd container is itself crash-looping or absent → **etcd is the
  problem**; read its logs, check `/var/lib/etcd` permissions and disk space.

Either way the repair is editing the file in
`/etc/kubernetes/manifests/`. There is nothing to restart: the kubelet watches
that directory and recreates the static pod when the file changes.

### 5. Single or multi-member, and how many for HA? (2 min)

```bash
$ETCD member list --write-out=table
```

One row on kind — a single member, no fault tolerance whatsoever.

For HA you want an **odd** number, normally **3**, sometimes 5. Raft needs a
quorum of `(n/2)+1` to accept writes:

| Members | Quorum | Failures tolerated |
|---|---|---|
| 1 | 1 | 0 |
| 2 | 2 | **0** |
| 3 | 2 | 1 |
| 4 | 3 | **1** |
| 5 | 3 | 2 |

Note rows 2 and 4: an even count tolerates no more failures than the odd number
below it, while adding cost and slowing every write. That is the whole reason
for "always odd". Beyond 5, write latency grows because more members must
acknowledge, so 5 is the practical maximum.

---

## The six answers

1. **Why key-value** — Kubernetes only ever fetches objects by path, never runs
   complex queries; the API server does all filtering. Key-value gives the
   fastest possible lookup with no schema to migrate as APIs evolve.

2. **Key path** — `/registry/pods/prod/web`. The convention is
   `/registry/<resource-type>/<namespace>/<name>`.

3. **Only the API server talks to etcd** — it is the single choke point for
   authentication, authorization, admission and validation. If the scheduler or
   kubelet wrote to etcd directly, none of those could be enforced. It also
   means an etcd outage presents as a total API outage.

4. **advertise vs listen** — `--listen-client-urls` is what etcd binds locally;
   `--advertise-client-urls` is what it publishes to clients, and is what the
   API server's `--etcd-servers` must match. Identical on a single node,
   different in a real cluster.

5. **`set` is v2** — the v3 API replaced `set` with `put` and `rm` with `del`.
   Kubernetes uses v3, so v2 commands see an empty store and appear to work,
   which is the confusing part. Confirm with `etcdctl version`.

6. **Secrets are not encrypted at rest by default** — they are base64-encoded in
   the API and stored as ordinary values in etcd, readable with `strings`.
   Encryption requires an `EncryptionConfiguration` on the API server, ideally
   backed by a KMS provider. RBAC protects the API; it does not protect the
   datastore.

---

## Carry this to the exam

**Static pod repair is the pattern.** Almost every control-plane task follows
the same three steps:

```bash
# 1. edit the manifest on the node
/etc/kubernetes/manifests/{kube-apiserver,etcd,kube-scheduler,kube-controller-manager}.yaml

# 2. the kubelet notices and recreates the pod -- no restart command exists
# 3. verify
crictl ps -a --name <component>          # from the node, when kubectl is down
kubectl get pods -n kube-system          # once the API server is back
```

A YAML syntax error in one of those files means the pod never starts and
`kubectl` never returns. `crictl logs -p` on the node is then your only view —
which is exactly why CKA 01 comes first.
