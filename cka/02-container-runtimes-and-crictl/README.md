# CKA 01 — Container Runtimes: CRI, OCI, and the three CLIs

**Time:** 45-60 minutes
**Prerequisites:** [Day 01](../../days/day-01-architecture-and-kind-cluster/)

Day 08 told you to run `docker exec devops-worker crictl images` and moved on.
This day explains what `crictl` actually is, why `docker` is not on your nodes,
and which of the three container CLIs to reach for.

**This matters for the exam**: the CKA lab environment runs containerd. There is
no `docker` command on the nodes. If your troubleshooting muscle memory is
`docker ps` and `docker logs`, you will lose time you do not have.

---

## Part 1 - Concepts

### 1.1 How we got here

```
2013   Docker appears. Its UX is so much better than the alternatives
       (rkt, LXC) that it becomes the default way to run a container.

2014   Kubernetes is built to orchestrate Docker -- specifically Docker.
       The two are tightly coupled. Nothing else is supported.

2016   Other runtimes want in. Kubernetes introduces the
       CONTAINER RUNTIME INTERFACE (CRI): a single interface any runtime
       can implement.

       But Docker predates CRI and does not speak it. Docker is still
       dominant, so Kubernetes writes DOCKERSHIM -- a translation layer,
       explicitly described by its own authors as a hack.

2020   Kubernetes announces dockershim's deprecation. The internet
       misreads this as "Docker is dead".

1.24   Dockershim is REMOVED. Kubernetes no longer talks to Docker Engine.
```

**What actually happened, precisely:** Kubernetes stopped supporting *Docker
Engine as a runtime*. It did **not** stop supporting Docker's *images*, because
those follow the OCI image spec. Every image you have ever built with
`docker build` still runs on Kubernetes today, unchanged. Day 08's
`app/build-images.sh` builds with Docker and runs on containerd. That works
because of the standard, not by luck.

### 1.2 CRI and OCI are two different standards

People conflate these constantly. They sit at different layers.

| | **CRI** (Container Runtime Interface) | **OCI** (Open Container Initiative) |
|---|---|---|
| Owned by | Kubernetes | a separate open standards body |
| Defines | how the **kubelet talks to a runtime** | how **images are built** and how **runtimes behave** |
| Consists of | a gRPC API | an **image spec** and a **runtime spec** |
| Implemented by | containerd, CRI-O | runc, crun, gVisor, Kata |

Read it top to bottom:

```
kubelet
   |  CRI  (gRPC)
   v
containerd            <- a CRI implementation, "high-level runtime"
   |  OCI runtime spec
   v
runc                  <- a "low-level runtime": actually creates the process,
                         namespaces and cgroups
```

**Docker was never a runtime in the low-level sense.** Docker is a suite: a CLI,
a REST API, build tooling, volume and network management, auth — and, at the
bottom, containerd driving runc. Kubernetes only ever needed that bottom part.
When containerd was split out as its own project, Kubernetes could talk to it
directly and everything above became unnecessary weight.

That is the whole story. containerd is now a **graduated CNCF project** and
installs standalone, with no Docker involved.

### 1.3 Three CLIs, and when to use each

This is the part worth memorising.

| Tool | From | Talks to | Use it for |
|---|---|---|---|
| **`ctr`** | containerd | containerd only | almost never. Debugging containerd itself |
| **`nerdctl`** | containerd | containerd only | general purpose. A near drop-in for `docker` |
| **`crictl`** | **Kubernetes** | **any CRI runtime** | **debugging a node. This is the exam one** |

**`ctr`** ships with containerd. It is deliberately minimal, exists for
containerd's own developers, and its own documentation says it is not intended
for general use. Its output format is unlike anything else. Avoid it — with one
exception noted in the lab.

**`nerdctl`** is the containerd community's Docker-compatible CLI. Swap `docker`
for `nerdctl` and most commands work verbatim, plus newer containerd features
Docker never exposed: encrypted images, lazy pulling, image signing, P2P
distribution. Good for a workstation. Usually not installed on a cluster node.

**`crictl`** comes from the Kubernetes community and speaks CRI, so it works
against containerd, CRI-O or anything else CRI-compatible. It is installed on
CKA exam nodes. **It is a debugging tool, not a container manager.**

> ### Do not create containers with crictl
>
> You technically can. Do not. The kubelet reconciles the node against what the
> API server says should be running, so any container it did not create is
> unrecognised and gets **deleted**. You will spend twenty minutes wondering why
> your container keeps vanishing.
>
> `crictl` is for **inspecting** what the kubelet already made.

### 1.4 crictl mapped to docker

| Task | docker | crictl |
|---|---|---|
| list containers | `docker ps` | `crictl ps` |
| list all, including exited | `docker ps -a` | `crictl ps -a` |
| list images | `docker images` | `crictl images` |
| pull an image | `docker pull X` | `crictl pull X` |
| logs | `docker logs X` | `crictl logs X` |
| exec | `docker exec -it X sh` | `crictl exec -it X sh` |
| inspect | `docker inspect X` | `crictl inspect X` |
| stats | `docker stats` | `crictl stats` |
| **list pods** | **no equivalent** | **`crictl pods`** |

That last row is the meaningful difference. Docker had no concept of a pod;
`crictl pods` shows the CRI's pod sandboxes, which is what the kubelet actually
manages.

### 1.5 Runtime endpoints

`crictl` needs to know which socket to talk to. Configure it once:

```yaml
# /etc/crictl.yaml
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
```

Or per-command with `--runtime-endpoint`, or via the
`CONTAINER_RUNTIME_ENDPOINT` environment variable.

Without configuration, older versions probe a list of well-known sockets in
order and print a deprecation warning each time. Common sockets:

| Runtime | Socket |
|---|---|
| containerd | `unix:///run/containerd/containerd.sock` |
| CRI-O | `unix:///var/run/crio/crio.sock` |
| cri-dockerd | `unix:///var/run/cri-dockerd.sock` |

---

## Part 2 - Hands-on lab

Everything here runs **on a node**, not against the API server. Get onto one:

```bash
docker exec -it devops-control-plane bash
```

Everything from here until "Step 6" is typed **inside** that shell.

### Step 1: Prove there is no Docker

```bash
which docker || echo "no docker on this node"
which crictl ctr
ps aux | grep -E "containerd|dockerd" | grep -v grep
```

`containerd` is running. `dockerd` is not, and never was. The nodes are Docker
*containers*, but there is no Docker *inside* them — that trips people up on
kind specifically.

```bash
cat /etc/crictl.yaml
systemctl status containerd --no-pager | head -5
```

### Step 2: crictl, the commands you will actually use

```bash
crictl version
crictl info | head -20

crictl pods                      # the pod sandboxes -- no docker equivalent
crictl ps                        # running containers
crictl ps -a                     # including exited -- where crashes show up
crictl images
```

Now correlate with what `kubectl` sees. In another terminal on your laptop:

```bash
kubectl get pods -n kube-system -o wide --field-selector spec.nodeName=devops-control-plane
```

Same workloads, two viewpoints: `kubectl` asks the API server what *should* run;
`crictl` asks the node what *is* running. **When those two disagree, you have
found your bug.** That is the entire reason `crictl` is on the exam.

### Step 3: Debug a container from the node

```bash
# find the apiserver container
crictl ps --name kube-apiserver

# grab its id (first column) and inspect it
CID=$(crictl ps --name kube-apiserver -q)
echo "$CID"

crictl logs --tail 20 "$CID"
crictl inspect "$CID" | head -40
crictl stats
```

Two flags worth knowing under exam pressure:

```bash
crictl ps -q                     # ids only -- scriptable
crictl logs -f "$CID"            # follow
crictl logs -p "$CID"            # PREVIOUS container, like kubectl logs --previous
```

`crictl logs -p` is the one that matters. When a control-plane static pod is
crash-looping, `kubectl logs` may not even work — the API server might be the
thing that is down. `crictl logs -p` on the node still does.

### Step 4: The `ctr` namespace gotcha

This one costs people real time.

```bash
ctr images ls
```

Empty. But you just saw images with `crictl images`. Now:

```bash
ctr namespaces ls
ctr -n k8s.io images ls | head
ctr -n k8s.io containers ls | head
```

There they are. **containerd has its own namespaces, unrelated to Kubernetes
namespaces**, and Kubernetes puts everything in `k8s.io`. `ctr` defaults to
`default`, which is empty on a Kubernetes node.

`crictl` has no such problem — it only ever looks where Kubernetes looks. That
alone is a good reason to prefer it.

### Step 5: Find the image your pod is really running

A genuinely useful cross-check when a deploy "did not take":

```bash
crictl images | grep devboard
crictl ps -a --name backend -o json 2>/dev/null | grep -m1 image || \
  crictl ps -a --name backend
```

Compare with what the Deployment claims:

```bash
# on your laptop
kubectl get deploy backend -n devboard \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

If they differ, you have Day 08's "rebuilt the same tag, nothing changed"
problem — and now you can prove it from the node rather than guessing.

```bash
exit                             # leave the node
```

### Step 6: nerdctl (read this, installation is optional)

`nerdctl` is not on kind nodes and is not on the exam. It matters on a
workstation where you have containerd but not Docker:

```bash
nerdctl run -d -p 8080:80 nginx:alpine
nerdctl ps
nerdctl build -t myapp:1.0 .
nerdctl compose up            # yes, compose too
```

Every one of those is the `docker` command with the name swapped. If you are
ever on a containerd-only machine, this is the tool — not `ctr`.

---

## Validate

```bash
docker exec devops-control-plane crictl pods | head -3
docker exec devops-control-plane crictl ps --name etcd -q
docker exec devops-control-plane ctr -n k8s.io images ls | wc -l
docker exec devops-control-plane sh -c 'ctr images ls | wc -l'   # 1 = header only
```

You are done when you can answer, without looking:

1. What is the difference between CRI and OCI?
2. Why did images built by Docker keep working after dockershim was removed?
3. Which of `ctr` / `nerdctl` / `crictl` do you use on a cluster node, and why?
4. Why must you not create containers with `crictl`?
5. Why does `ctr images ls` come back empty on a Kubernetes node?

---

## Break it

**A. Create a container with crictl and watch the kubelet eat it.**

Rather than fighting the sandbox syntax, observe the same principle the easy
way — delete a container the kubelet owns:

```bash
docker exec devops-control-plane sh -c '
  CID=$(crictl ps --name kube-scheduler -q)
  echo "killing $CID"
  crictl stop "$CID"
  sleep 12
  crictl ps --name kube-scheduler
'
```

A **new** container id is running. You did not create it; the kubelet did,
because the static pod manifest still says the scheduler should exist. The
kubelet reconciles the node against declared state — which is precisely why a
container *you* create outside that declaration gets removed instead.

**B. Point crictl at a socket that does not exist.**

```bash
docker exec devops-control-plane \
  crictl --runtime-endpoint unix:///var/run/crio/crio.sock ps
```

A connection error naming the socket. On a real node with several runtimes
configured, this is how you end up querying the wrong one and concluding
"there are no containers running" while the cluster is perfectly healthy.

**C. Use the wrong tool for logs.**

```bash
docker exec devops-control-plane sh -c 'docker ps' 2>&1 | head -2
```

`docker: not found`. Recognise that instantly on the exam and reach for
`crictl` without losing thirty seconds to confusion.

---

## Exam-style tasks

Timed. No looking things up first.

1. On the control-plane node, list every **exited** container and identify which
   one has the highest restart count. *(2 min)*
2. Retrieve the last 20 log lines of the `kube-controller-manager` container
   using only node-level tools — `kubectl` is off limits. *(2 min)*
3. List every image present on the node, using both `crictl` and `ctr`. Explain
   why the two commands need different arguments. *(3 min)*
4. Determine which container runtime and version each node runs, without
   entering any node. *(2 min)*

Answers in [`solution/`](solution/).

---

## Cheat card

```bash
# on the node
crictl pods                 # pod sandboxes  (no docker equivalent)
crictl ps                   # running containers
crictl ps -a                # including exited -- crashes live here
crictl ps -q                # ids only
crictl images
crictl logs <id>
crictl logs -p <id>         # PREVIOUS container -- the important one
crictl exec -it <id> sh
crictl inspect <id>
crictl stats

# containerd's own namespaces -- Kubernetes uses k8s.io
ctr namespaces ls
ctr -n k8s.io images ls
ctr -n k8s.io containers ls

# which runtime is each node on? (from your laptop, no ssh needed)
kubectl get nodes -o wide
kubectl get node <n> -o jsonpath='{.status.nodeInfo.containerRuntimeVersion}{"\n"}'
```

| Layer | Standard | Implementations |
|---|---|---|
| kubelet to runtime | **CRI** (Kubernetes) | containerd, CRI-O |
| runtime to kernel | **OCI runtime spec** | runc, crun, gVisor, Kata |
| image format | **OCI image spec** | why `docker build` output still works |

---

**Next: [CKA 02 — etcd and cluster data](../03-etcd-and-cluster-data/)**
