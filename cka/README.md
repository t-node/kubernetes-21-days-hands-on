# CKA track — certification-specific material

The 21 days teach you to **deploy an application** on Kubernetes. The
**Certified Kubernetes Administrator** exam tests something different: running
and repairing the **cluster itself**. This track covers the gap.

Days here are numbered separately and can be taken at any point after Day 01.
They cross-link back to the main track wherever a topic overlaps.

---

## Why a separate track

| The 21 days | The CKA |
|---|---|
| deploy and operate an app | build, break and repair a cluster |
| ClusterIP, Ingress, HPA | etcd, certificates, kubeadm, upgrades |
| `kubectl` from outside | `crictl`, `etcdctl`, systemd, static pods on the node |
| "does my app work?" | "is my control plane healthy?" |

Roughly 40 percent overlaps. This track holds the other 60 percent.

---

## Available now

| # | Topic | Fills the gap in |
|---|---|---|
| [01](01-container-runtimes-and-crictl/) | Container runtimes: CRI, OCI, `ctr` / `nerdctl` / `crictl` | Day 01, Day 08 used `crictl` without ever teaching it |
| [02](02-etcd-and-cluster-data/) | etcd: key-value model, `etcdctl`, the `/registry` tree | nothing in the main track touched etcd hands-on |
| [03](03-commands-and-arguments/) | `ENTRYPOINT`/`CMD` vs `command`/`args`, pod immutability, `replace --force` | the main track never explained why a container exits |
| [04](04-kubeconfig-and-the-api/) | kubeconfig in depth, API groups, `kubectl proxy`, raw `curl` | Day 01 showed `current-context` and stopped |
| [05](05-certificates-api-and-authorization/) | CSR objects, approve/deny, authorization modes | Day 19 said "do not run it" |

## Pending the rest of the transcript

The source course has **310 lectures**; the pastes so far have supplied **43**
(lectures 1-13, 91-107 and 152-164). These topics are named in the section list but their lectures
have not arrived yet, so nothing here covers them:

- kube-scheduler, kube-controller-manager, kubelet, kube-proxy in depth
- Secrets (the lecture cut off mid-sentence — Day 10 covers the ground)
- **etcd backup and restore** — a near-guaranteed exam task
- kubeadm cluster bootstrap, cluster upgrades, OS upgrades
- TLS certificate *generation* for cluster components (the CSR API is now covered)
- Admission controllers
- Networking: CNI, CoreDNS, kube-proxy internals, NetworkPolicy
- Storage: CSI, volume types
- Scheduling: static pods, multiple schedulers, priority classes
- JSONPath, imperative commands, troubleshooting drills, mock exams

I will not invent content for these. Send the remaining lectures and they get
built the same way.

---

## About the exam

From the certification lecture in the transcript:

| | |
|---|---|
| Format | **performance-based**, not multiple choice — you do real tasks in a real cluster |
| Duration | 3 hours |
| Delivery | online, remotely proctored |
| Retake | one free retake within 12 months |
| Documentation | **the official Kubernetes docs are allowed during the exam** |

That last point shapes how you should prepare. **Do not memorise YAML.** Get
fast at finding it: know which page has the manifest you need, and get fluent
with `kubectl explain`, `--dry-run=client -o yaml`, and imperative generators.
Speed matters more than recall.

The environment is containerd-based, so `docker` commands are not available on
the nodes — which is exactly why track day 01 exists.
