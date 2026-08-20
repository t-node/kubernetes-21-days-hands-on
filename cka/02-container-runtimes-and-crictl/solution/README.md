# CKA 01 solution

## Exam-style task answers

### 1. Exited containers, highest restart count (2 min)

```bash
docker exec devops-control-plane crictl ps -a --state exited
```

`crictl ps` has no restart-count column. Restart counts belong to the **pod**,
not the container, so get them from the API server:

```bash
kubectl get pods -A --sort-by='.status.containerStatuses[0].restartCount' \
  -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,\
RESTARTS:.status.containerStatuses[0].restartCount | tail -5
```

**The point of the task:** knowing which tool owns which fact. `crictl` sees
containers on one node; restart counts are cluster state.

### 2. Controller-manager logs, node tools only (2 min)

```bash
docker exec devops-control-plane sh -c '
  CID=$(crictl ps --name kube-controller-manager -q)
  crictl logs --tail 20 "$CID"
'
```

If it is crash-looping, the running container has no useful output — use the
previous one:

```bash
docker exec devops-control-plane sh -c '
  CID=$(crictl ps -a --name kube-controller-manager -q | head -1)
  crictl logs -p "$CID"
'
```

There is also a fallback that needs no runtime tooling at all:

```bash
docker exec devops-control-plane sh -c 'ls /var/log/containers/ | grep controller-manager'
docker exec devops-control-plane sh -c 'tail -20 /var/log/containers/kube-controller-manager-*.log'
```

Worth knowing: if the runtime itself is unhealthy, those files are still there.

### 3. Images with both tools (3 min)

```bash
docker exec devops-control-plane crictl images
docker exec devops-control-plane ctr -n k8s.io images ls
```

`ctr` needs `-n k8s.io` because **containerd has its own namespaces**, unrelated
to Kubernetes namespaces, and the kubelet puts everything in `k8s.io`. `ctr`
defaults to the `default` namespace, which is empty on a Kubernetes node.
`crictl` speaks CRI and only ever looks where Kubernetes looks, so it needs no
such flag.

### 4. Runtime per node, without entering a node (2 min)

```bash
kubectl get nodes -o wide
```

The `CONTAINER-RUNTIME` column. Scriptable:

```bash
kubectl get nodes -o custom-columns=\
NAME:.metadata.name,RUNTIME:.status.nodeInfo.containerRuntimeVersion,\
KUBELET:.status.nodeInfo.kubeletVersion,OS:.status.nodeInfo.osImage
```

Expect `containerd://1.7.x`. The kubelet reports this in `.status.nodeInfo`, so
no node access is required — a useful reflex when you are asked about a node you
cannot reach.

---

## The five answers

1. **CRI vs OCI** — CRI is Kubernetes' gRPC interface between the kubelet and a
   runtime (containerd, CRI-O). OCI is a separate standards body defining an
   *image spec* (how images are built) and a *runtime spec* (how a low-level
   runtime such as runc behaves). Different layers: CRI is kubelet-to-runtime,
   OCI is runtime-to-kernel plus the image format.

2. **Why Docker images still work** — dockershim removal dropped support for
   Docker *Engine as a runtime*. Images are unaffected because `docker build`
   emits OCI-compliant images, which containerd runs natively.

3. **Which CLI on a node** — `crictl`. It is from the Kubernetes community,
   works against any CRI runtime, and is installed on exam nodes. `ctr` is a
   containerd-internal debugging tool with awkward output and a namespace trap.
   `nerdctl` is a Docker-compatible CLI for workstations and is generally not
   installed on cluster nodes.

4. **Why not create containers with crictl** — the kubelet reconciles the node
   against what the API server declares. A container it did not create is
   unrecognised and gets deleted. `crictl` is for inspection.

5. **Why `ctr images ls` is empty** — wrong containerd namespace. Use
   `ctr -n k8s.io images ls`.

---

## The one habit to take to the exam

When something is wrong on a node, ask **two** questions in this order:

```bash
kubectl get pods -o wide        # what SHOULD be running here?
crictl ps -a                    # what IS running here?
```

The gap between those two answers is the bug. Almost every node-level CKA
troubleshooting question is solved by noticing it.
