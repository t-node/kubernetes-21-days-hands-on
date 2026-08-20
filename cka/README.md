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
| [06](06-cluster-maintenance/) | node drains, version skew, kubeadm upgrades, **etcd backup and restore** | flagged twice as the biggest gap |

## Pending the rest of the transcript

The full 312-lecture transcript is now indexed locally (see below). **169
lectures of new material remain to be built** — the roadmap is at the bottom. These topics are named in the section list but their lectures
have not arrived yet, so nothing here covers them:

- kube-scheduler, kube-controller-manager, kubelet, kube-proxy in depth
- Secrets (the lecture cut off mid-sentence — Day 10 covers the ground)
- kubeadm cluster bootstrap and HA design (upgrades are now covered)
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

---

## Roadmap — what is left to build

The full 312-lecture transcript is indexed at `.transcript/` (gitignored: it is
copyrighted course material, kept locally only). `.transcript/index.json` lists
every lecture; `.transcript/L###.txt` holds each one's text.

**169 lectures of new material remain**, grouped by topic and ordered by how
much they matter for the exam:

| Topic cluster | Lectures | Chars | Priority |
|---|---:|---:|---|
| TLS certificates end to end | 9 | 62,872 | very high |
| Troubleshooting: app / control plane / worker node | 7 | 41,177 | very high |
| JSONPath and custom-columns | 1 | 10,198 | very high |
| Networking internals: namespaces, CNI, DNS, services | 18 | 115,805 | high |
| Scheduling: static pods, priority, profiles, admission | 25 | 139,365 | high |
| Security: service accounts, contexts, image, NetworkPolicy | 11 | 62,984 | high |
| Ingress and Gateway API (deeper than Day 20) | 4 | 46,034 | medium |
| kubeadm install, HA design, etcd in HA | 8 | 70,716 | medium |
| Storage internals and CSI | 11 | 46,238 | medium |
| Kustomize | 17 | 94,953 | medium |
| Helm | 8 | 43,628 | medium |
| Encryption at rest, multi-container, VPA, in-place resize | 9 | 57,375 | medium |
| CRDs, custom controllers, operators | 3 | 15,424 | low |
| Core concepts recap, imperative vs declarative | 24 | 134,580 | low |
| Mock exam worked solutions -> exam-style task banks | 3 | 96,644 | as material |

Priority reflects CKA exam weighting, not intrinsic interest. The "very high"
rows are the ones people fail on.

To continue, just say which cluster to build next — no pasting required, the
source is already on disk.
