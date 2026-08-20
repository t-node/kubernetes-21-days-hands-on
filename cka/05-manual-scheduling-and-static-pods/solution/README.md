# CKA 05 solution

## Exam-style task answers

### 1. Pod on a specific node without the scheduler (3 min)

```bash
kubectl run nginx-manual --image=nginx:alpine \
  --overrides='{"spec":{"nodeName":"devops-worker2"}}'
kubectl get pod nginx-manual -o wide
```

Or declaratively — clearer, and what you would commit:

```bash
kubectl run nginx-manual --image=nginx:alpine --dry-run=client -o yaml > p.yaml
# add   nodeName: devops-worker2   under spec:
kubectl apply -f p.yaml
```

**`nodeName` must be set at creation.** It is immutable afterwards, so if the
pod already exists you need the Binding route below.

### 2. Find the static pod directory (2 min)

```bash
docker exec devops-control-plane grep staticPodPath /var/lib/kubelet/config.yaml
```

If that yields nothing, it is an older cluster using the flag:

```bash
docker exec devops-control-plane sh -c \
  "ps aux | grep [k]ubelet | xargs -n1 | grep pod-manifest-path"
```

**The reliable procedure:** find the kubelet's `--config` flag, open that file,
read `staticPodPath`. Only if there is no `--config` do you look for
`--pod-manifest-path`. Never assume `/etc/kubernetes/manifests` — it is the
kubeadm default, not a rule.

### 3. Create a static pod (4 min)

```bash
kubectl run web --image=nginx:alpine --dry-run=client -o yaml > /tmp/web.yaml
docker cp /tmp/web.yaml devops-control-plane:/etc/kubernetes/manifests/web.yaml
sleep 20
kubectl get pods -A | grep web
```

Expect `web-devops-control-plane`. Two marks people lose here: putting the file
on the **wrong node** (it must be the node you want it to run on), and
forgetting that the mirror pod's name has the node name appended.

On the real exam you would `ssh` to the node first, then write the file.

### 4. Delete a static pod (2 min)

```bash
docker exec devops-control-plane rm /etc/kubernetes/manifests/web.yaml
sleep 15
kubectl get pods -A | grep -c web
```

**`kubectl delete pod` does not work.** It removes the mirror; the kubelet still
sees the file and recreates it within seconds. If a task says "delete this pod"
and it keeps returning, you are looking at a static pod — check for the
`-<nodename>` suffix and a `Node` ownerReference.

### 5. Pending with `nodeName` already set (2 min)

Two causes, and they are distinguishable:

1. **The named node does not exist**, or its kubelet is not running. No kubelet
   is watching for that name, so nothing claims the pod. Check
   `kubectl get nodes` and the node's kubelet status.
2. **The node cannot fit it** — the kubelet accepted the pod, evaluated it
   locally and rejected it. Status shows `OutOfcpu` or `OutOfmemory` rather than
   plain `Pending`.

The general point: `nodeName` set means **scheduling already happened**. Stop
investigating the scheduler; the problem is on the node.

---

## The six answers

1. **`spec.nodeName`**, written via a **Binding** object POSTed to the pod's
   `/binding` subresource.

2. Because `nodeName` is **immutable** — it is not one of the five fields a pod
   allows you to change (CKA 08). The Binding API is the supported way to assign
   an existing pod.

3. **Creates** the pod from the file; **restarts** the container if it dies;
   **recreates** the pod if the file changes; **deletes** the pod if the file is
   removed.

4. Because the kubelet only understands **Pods**. Deployments and everything
   else are reconciled by controllers in the control plane, which is exactly
   what static pods exist to work without.

5. **Remove the file** from the kubelet's `staticPodPath` on that node. Deleting
   the mirror pod through the API only removes the mirror.

6. A static pod is created by the **kubelet from a file** and needs no control
   plane; a DaemonSet pod is created by a **controller through the API server**.
   You delete a static pod by removing its file, a DaemonSet pod by deleting the
   DaemonSet. Static pods can host the control plane itself; DaemonSets cannot,
   because they need the control plane to exist first. (Both are ignored by the
   scheduler.)

---

## Carry this to the exam

**Two reflexes.**

When a pod will not schedule, look at `nodeName` before anything else:

```bash
kubectl get pod X -o jsonpath='{.spec.nodeName}'
```

Empty → the scheduler has not acted. Set → the scheduler is finished and the
problem is on that node.

And when a pod refuses to stay deleted, check whether it is static:

```bash
kubectl get pod X -o jsonpath='{.metadata.ownerReferences[0].kind}'   # Node
```

`Node`, plus a name ending in `-<nodename>`, means the answer is `rm`, on that
node, not `kubectl delete`.
