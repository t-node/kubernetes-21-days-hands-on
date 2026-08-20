# CKA 06 solution

| Script | Does |
|---|---|
| `etcd-snapshot.sh` | snapshot, verify key count, copy off the node |
| `etcd-restore.sh` | the full four-step restore, with a rollback path |
| `backup-by-api.sh` | enumerate every kind and dump it — what `get all` misses |

## The restore drill, start to finish

```bash
kubectl create namespace restore-proof
bash etcd-snapshot.sh
kubectl delete namespace restore-proof
bash etcd-restore.sh
sleep 30
kubectl get ns restore-proof        # it is back
```

**Do this on kind, repeatedly, until it is boring.** If it breaks,
`bash cluster/recreate-cluster.sh` costs 90 seconds. That is the entire reason
to practise here rather than on something that matters.

## Exam-style task answers

### 1. Snapshot to /opt/etcd-backup.db with key count (5 min)

```bash
kubectl -n kube-system exec etcd-devops-control-plane -- sh -c \
  "ETCDCTL_API=3 etcdctl snapshot save /var/lib/etcd/snapshot.db \
   --endpoints=https://127.0.0.1:2379 \
   --cacert=/etc/kubernetes/pki/etcd/ca.crt \
   --cert=/etc/kubernetes/pki/etcd/server.crt \
   --key=/etc/kubernetes/pki/etcd/server.key"

docker cp devops-control-plane:/var/lib/etcd/snapshot.db /opt/etcd-backup.db

kubectl -n kube-system exec etcd-devops-control-plane -- \
  etcdutl snapshot status /var/lib/etcd/snapshot.db --write-out=table
```

On a real exam node etcdctl is on the host, so it is a single command with no
`exec`. The three certificate flags are the part to have in muscle memory.

### 2. Evacuate a node with no downtime (5 min)

```bash
kubectl get pods -n devboard -o wide          # check spread first
kubectl drain devops-worker --ignore-daemonsets --delete-emptydir-data
# ...patch the OS...
kubectl uncordon devops-worker
```

Two things graders look for: **`--ignore-daemonsets`** (drain refuses without
it) and **`uncordon` afterwards** — leaving a node cordoned is the most common
half-finished answer.

If drain hangs, a PodDisruptionBudget is blocking it. Scale up rather than
reaching for `--force`.

### 3. Restore a deleted namespace (15 min)

```bash
# 1. put the snapshot where the etcd pod can read it
docker cp /opt/etcd-backup.db devops-control-plane:/var/lib/etcd/snapshot.db

# 2. restore into a NEW directory
kubectl -n kube-system exec etcd-devops-control-plane -- \
  etcdutl snapshot restore /var/lib/etcd/snapshot.db --data-dir=/var/lib/etcd/_restore

# 3. move it out of the live data dir
docker exec devops-control-plane sh -c \
  "mv /var/lib/etcd/_restore /var/lib/etcd-from-backup"

# 4. repoint the HOSTPATH VOLUME (not --data-dir)
docker exec devops-control-plane sh -c \
  "sed -i 's|path: /var/lib/etcd$|path: /var/lib/etcd-from-backup|' \
   /etc/kubernetes/manifests/etcd.yaml"

# 5. wait for the kubelet to recreate the pod
sleep 60 && kubectl get ns
```

Or just `bash etcd-restore.sh`.

**The two things that fail this task:**
- editing `--data-dir` instead of the `hostPath` volume. The flag is a
  *container* path; the hostPath is what maps it to real storage. Change the
  flag alone and etcd starts on an **empty** database — cluster up, everything
  gone.
- restoring into a directory that already exists. `snapshot restore` refuses,
  on purpose, so you always retain a fallback.

### 4. Version skew report (3 min)

```bash
kubectl get --raw /version | python -c "import sys,json;d=json.load(sys.stdin);print('apiserver',d['gitVersion'])"
kubectl get nodes -o custom-columns=NAME:.metadata.name,KUBELET:.status.nodeInfo.kubeletVersion
```

Then state the rule: the kubelet may be up to **three** minor versions older
than the API server (two, before Kubernetes 1.28) and **never newer**. If
apiserver is 1.31 and kubelets are 1.31, skew is zero and supported.

Remember `kubectl get nodes` reports **kubelet** versions, not the API server's
— which is exactly why the control plane can be upgraded while that column still
shows the old number.

### 5. Back up all ConfigMaps and Secrets (4 min)

```bash
kubectl get configmaps,secrets --all-namespaces -o yaml > /tmp/cm-secrets-backup.yaml
grep -c "kind: ConfigMap" /tmp/cm-secrets-backup.yaml
grep -c "kind: Secret"    /tmp/cm-secrets-backup.yaml
```

Worth saying out loud: this file now contains **every Secret in the cluster in
base64**, which is to say in plaintext. It needs the same protection as the
cluster itself — encrypted at rest, access-controlled, never in git.

---

## The seven answers

1. **N-3** since Kubernetes 1.28 (N-2 before). kube-proxy matches the kubelet.

2. **`kubectl`** — it may be one minor version *ahead* of the API server, as
   well as one behind. Every other component must be at or below it.

3. Because that column reports the **kubelet's** version, not the API server's.
   Upgrading the control plane does not touch kubelets, so the display only
   changes after you upgrade the kubelet package on each node.

4. **The kubelet** (and `kubectl`). `kubeadm` upgrades the control-plane static
   pods by swapping their images; the kubelet is a systemd service and is your
   job, via the OS package manager.

5. Restore writes a **complete new data directory** and assigns a new cluster ID
   and member ID, so the restored member cannot rejoin its old cluster and
   corrupt it. Refusing an existing directory prevents destroying the data you
   might still need to fall back to — which is also what makes a restore
   attempt safe.

6. `/etc/kubernetes/manifests/etcd.yaml`, and the **`hostPath` volume path**,
   not the `--data-dir` flag. No restart command exists: the kubelet watches the
   directory and recreates the static pod.

7. On EKS/GKE/AKS the **control plane is the provider's** — you have no node
   access and no etcd endpoint. API-level backup (Velero) is the only option,
   and the provider handles etcd durability themselves.

---

## Carry this to the exam

**The restore is muscle memory or it is nothing.** Four steps:

```
restore to a NEW dir  ->  move it into place  ->  edit the hostPath  ->  wait
```

No service restart anywhere. The kubelet does it.

**And remember which commands need certificates:**

| Command | Talks to a live etcd | Needs `--endpoints` + 3 certs |
|---|---|---|
| `snapshot save` | **yes** | **yes** |
| `snapshot status` | no | no |
| `snapshot restore` | no | no |
