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

## The curriculum

**[CURRICULUM.md](CURRICULUM.md) is the ordered path.** It maps all 312 source
lectures to assignments, shows what each one builds on, and proves nothing is
missing: 200 lectures have transcript content and all 200 are accounted for.

33 assignments, in course order. Six are built:

| # | Assignment | Section |
|---|---|---|
| [02](02-container-runtimes-and-crictl/) | Container Runtimes: CRI, OCI, `crictl` | Core Concepts |
| [03](03-etcd-and-cluster-data/) | etcd and Cluster Data | Core Concepts |
| [08](08-commands-and-arguments/) | Commands and Arguments | App Lifecycle |
| [12](12-cluster-maintenance/) | Cluster Maintenance and etcd Backup/Restore | Cluster Maintenance |
| [14](14-kubeconfig-and-the-api/) | KubeConfig and the API | Security |
| [15](15-certificates-api-and-authorization/) | Certificates API and Authorization | Security |

The remaining 27 are listed in CURRICULUM.md with their lecture ranges.

Reference material for the source course lives at
[kodekloudhub/certified-kubernetes-administrator-course](https://github.com/kodekloudhub/certified-kubernetes-administrator-course).

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
