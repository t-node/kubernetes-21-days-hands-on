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
missing: 200 lectures have transcript content and **all 200 are accounted for**.

**All 33 assignments are built.**

| # | Assignment | Section |
|---|---|---|
| [01](01-control-plane-components/) | Control Plane Components in Depth | Core Concepts |
| [02](02-container-runtimes-and-crictl/) | Container Runtimes: CRI, OCI, `crictl` | Core Concepts |
| [03](03-etcd-and-cluster-data/) | etcd and Cluster Data | Core Concepts |
| [04](04-imperative-declarative-and-apply/) | Imperative vs Declarative, and `kubectl apply` | Core Concepts |
| [05](05-manual-scheduling-and-static-pods/) | Manual Scheduling and Static Pods | Scheduling |
| [06](06-priority-schedulers-profiles/) | Priority Classes, Multiple Schedulers, Profiles | Scheduling |
| [07](07-admission-controllers/) | Admission Controllers, Webhooks and CEL Policies | Scheduling |
| [08](08-commands-and-arguments/) | Commands and Arguments | App Lifecycle |
| [09](09-encryption-at-rest/) | Encrypting Secret Data at Rest | App Lifecycle |
| [10](10-multi-container-and-init/) | Multi-Container Pods, Init Containers, Sidecars | App Lifecycle |
| [11](11-autoscaling-vpa-inplace/) | In-Place Resize and the Vertical Pod Autoscaler | App Lifecycle |
| [12](12-cluster-maintenance/) | Cluster Maintenance and etcd Backup/Restore | Cluster Maintenance |
| [13](13-tls-in-kubernetes/) | TLS in Kubernetes | Security |
| [14](14-kubeconfig-and-the-api/) | KubeConfig and the API | Security |
| [15](15-certificates-api-and-authorization/) | Certificates API and Authorization | Security |
| [16](16-service-accounts/) | Service Accounts and Tokens | Security |
| [17](17-image-security-and-security-contexts/) | Image Security and Security Contexts | Security |
| [18](18-network-policies/) | Network Policies | Security |
| [19](19-crds-controllers-operators/) | Custom Resources, Controllers and Operators | Security |
| [20](20-storage-internals-and-csi/) | Storage Internals, Provisioners and CSI | Storage |
| [21](21-linux-networking-foundations/) | Linux Networking Foundations | Networking |
| [22](22-pod-networking-and-cni/) | Pod Networking and CNI | Networking |
| [23](23-service-networking/) | Service Networking | Networking |
| [24](24-dns-and-coredns/) | DNS and CoreDNS | Networking |
| [25](25-ingress-gateway-in-depth/) | Ingress and the Gateway API in Depth | Networking |
| [26](26-cluster-design-and-ha/) | Cluster Design and High Availability | Design & Install |
| [27](27-build-a-cluster-with-kubeadm/) | Build a Cluster with kubeadm | Design & Install |
| [28](28-helm/) | Helm | Helm |
| [29](29-kustomize-structure-transformers/) | Kustomize: Structure and Transformers | Kustomize |
| [30](30-kustomize-patches-overlays-components/) | Kustomize: Patches, Overlays, Components | Kustomize |
| [31](31-troubleshooting/) | Troubleshooting: The Three Failure Domains | Troubleshooting |
| [32](32-jsonpath/) | JSONPath and Output Formatting | Other Topics |
| [33](33-mock-exam/) | Mock Exam Task Bank | Mock Exams |

### Every assignment has the same shape

| Part | What it is |
|---|---|
| **1 — Concepts** | the mechanism, with the traps named |
| **2 — Hands-on lab** | run it; several assignments break the cluster on purpose |
| **3 — Challenges** | five questions with no commands given |
| **4 — Verify** | `bash solution/verify.sh` checks every claim the lab made |
| **5 — Exam notes** | fast paths and a trap list |

`solution/README.md` holds the challenge answers. **Do not read it first.**

### If you are short of time

**[CKA 31](31-troubleshooting/) first** — troubleshooting is 30% of the exam and
the domain people prepare for least. Then **[CKA 33](33-mock-exam/)**, timed, to
find out what else is missing.

### Things worth knowing before you start

- **Some assignments create a second cluster.**
  [CKA 18](18-network-policies/) (Calico), [CKA 11](11-autoscaling-vpa-inplace/)
  (a feature gate) and [CKA 26](26-cluster-design-and-ha/) (three control planes)
  each build a throwaway kind cluster so your working one is untouched.
- **Some deliberately break the cluster.** [CKA 13](13-tls-in-kubernetes/),
  [CKA 22](22-pod-networking-and-cni/) and [CKA 31](31-troubleshooting/) all ship
  a `restore.sh`. Take the backup the assignment tells you to take.
- **A few need extra tooling**: `helm` for [CKA 28](28-helm/), and `openssl` for
  the certificate assignments.

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
