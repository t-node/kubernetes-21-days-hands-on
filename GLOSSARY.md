# Glossary

Every term used in this course, defined in a line or two, with the day it is
introduced.

---

## Core objects

**Pod** — the smallest schedulable unit: one or more containers sharing a
network namespace (one IP, `localhost` between them) and optionally volumes.
Ephemeral: never restarted in place, always replaced with a new name and IP. [02]

**ReplicaSet** — keeps exactly N pods matching its selector alive. Knows nothing
about versions. You never create one directly. [04]

**Deployment** — manages ReplicaSets. Changing the pod template creates a new
ReplicaSet and shifts replicas across gradually, giving rolling updates and
rollback. The default controller for stateless workloads. [04]

**StatefulSet** — like a Deployment but with stable ordinal pod names
(`postgres-0`), one PVC per replica, stable per-pod DNS, and ordered
create/delete/update. For workloads where identity matters. [15]

**DaemonSet** — one pod per node, or per matching node. No `replicas` field; the
node count is the replica count. For log shippers, metrics agents, CNI. [18]

**Job / CronJob** — run to completion once, or on a schedule.

**Service** — a stable virtual IP and DNS name in front of a changing set of
pods, selected by labels. L4 (per connection), not L7 (per request). [06]

**Ingress** — L7 HTTP routing rules: hostnames, paths, TLS. Inert without an
ingress **controller** running to implement them. [20]

**Gateway API** — the successor to Ingress. GatewayClass (provider), Gateway
(operator), HTTPRoute (developer). Typed fields instead of annotations. [20]

**Namespace** — a virtual cluster: a scope for object names, an RBAC boundary, a
quota boundary. Not a security or network boundary by itself. [03]

**ConfigMap** — non-sensitive configuration as key/value strings. [09]

**Secret** — the same, base64-encoded and treated differently by RBAC,
encryption-at-rest and node storage. Base64 is encoding, not encryption. [10]

**PersistentVolume (PV)** — a piece of storage in the cluster. **Cluster-scoped.** [14]

**PersistentVolumeClaim (PVC)** — a request for storage. **Namespaced.** Pods
reference PVCs, never PVs. [14]

**StorageClass** — describes a *kind* of storage and names the provisioner that
creates PVs on demand. [14]

**HorizontalPodAutoscaler (HPA)** — changes the replica count based on a metric.
Cannot add nodes; cannot scale to zero. [17]

**ServiceAccount** — an identity for a **pod**. A real API object, unlike users. [19]

**Role / ClusterRole** — a set of permissions, namespaced or cluster-wide. [19]

**RoleBinding / ClusterRoleBinding** — grants a role to subjects. A RoleBinding
may reference a ClusterRole, granting it only in that namespace. [19]

**PodDisruptionBudget (PDB)** — a floor on availability during *voluntary*
disruption such as a drain. Does not protect against a node crash. [18]

**ResourceQuota** — caps aggregate consumption in a namespace. [03]

**LimitRange** — constrains individual containers and supplies defaults. The
mandatory companion to a ResourceQuota. [03]

---

## Cluster components

**Control plane** — the decision-making half: API server, etcd, scheduler,
controller manager. [01]

**Data plane** — the executing half: worker nodes running kubelet, kube-proxy
and a container runtime. [01]

**kube-apiserver** — the only door into the cluster. Authenticates, authorises,
validates and persists. The only component that talks to etcd. Port 6443. [01]

**etcd** — the distributed key-value store holding all cluster state. Lose it,
lose the cluster. [01]

**kube-scheduler** — picks a node for each unscheduled pod by filtering then
scoring. Does **not** start containers. [01]

**kube-controller-manager** — dozens of reconciliation loops driving actual
state toward desired state. [01]

**cloud-controller-manager** — translates Kubernetes concepts into cloud API
calls. Absent on kind, which is why `type: LoadBalancer` stays `<pending>`. [01]

**kubelet** — the agent on every node. The only thing that actually starts
containers. A systemd service, not a pod. [01]

**kube-proxy** — programs iptables or IPVS rules implementing Services. [01]

**containerd** — the container runtime. Speaks CRI to the kubelet. [01]

**CNI** — the plugin giving pods IPs and cross-node connectivity. Mandatory. [01]

**CoreDNS** — in-cluster DNS. Makes `http://backend:8080` resolve. [06]

**metrics-server** — scrapes kubelets and serves `metrics.k8s.io`, which
`kubectl top` and the HPA consume. About a minute of in-memory data; not
monitoring. [16]

---

## Concepts

**Declarative** — you describe desired state and controllers reconcile toward
it. The opposite of issuing imperative commands. [01]

**Reconciliation loop** — the permanent "if actual != desired, act" cycle that
makes `kubectl apply` idempotent and pods self-healing. [01]

**Label** — an arbitrary key/value pair used for **selection**. Nothing in
Kubernetes references another object by name; everything uses selectors. [04]

**Annotation** — non-identifying metadata for humans and tools. Cannot be
selected on. [04]

**Selector** — a label query. The glue between Services and pods, Deployments
and pods, and much else. [04]

**ownerReference** — metadata pointing at a parent object, driving cascading
deletion. [04]

**Ephemeral** — pods are non-permanent: replaced rather than restarted, with a
new name and IP, losing anything on the container filesystem. [02]

**Endpoints / EndpointSlice** — the list of Ready pod IPs behind a Service.
`<none>` is the single most diagnostic thing in Kubernetes. [06]

**ClusterIP** — a virtual IP reachable only inside the cluster. The default
Service type. [06]

**NodePort** — a port in 30000-32767 opened on **every** node. [07]

**Headless Service** — `clusterIP: None`. No virtual IP; DNS returns pod IPs.
Required by StatefulSets. [06, 15]

**Liveness probe** — "is this process wedged?" Failure means **restart**. Must
never check a dependency. [13]

**Readiness probe** — "can this pod serve right now?" Failure means **removed
from endpoints**, with no restart. Dependencies belong here. [13]

**Startup probe** — a grace period for slow starters. Suspends the other two
until it passes. [13]

**Requests** — what the **scheduler** reserves. A node is full when the sum of
requests reaches allocatable, regardless of actual usage. [16]

**Limits** — what the **kernel** enforces. Exceeding CPU throttles; exceeding
memory OOMKills. [16]

**QoS class** — Guaranteed (requests equal limits), Burstable, BestEffort.
Determines eviction order under node pressure. [16]

**OOMKilled** — the kernel killed a container for exceeding its memory limit.
Exit code 137. [16]

**Taint** — on a **node**; repels pods. `NoSchedule`, `PreferNoSchedule`,
`NoExecute`. [18]

**Toleration** — on a **pod**; permission to ignore a taint. **Permission, not
attraction** — you also need affinity to make the pod go there. [18]

**Affinity / anti-affinity** — the pod's preference for nodes (node affinity) or
relative to other pods (pod affinity). `required` is a hard filter; `preferred`
only scores. [18]

**Topology spread constraint** — even distribution across nodes or zones,
without the replica cap that required anti-affinity imposes. [18]

**Static pod** — a pod the kubelet starts from a file on disk, bypassing the
scheduler entirely. How the control plane bootstraps. [01, 18]

**Init container** — runs to completion before app containers start.
Kubernetes' answer to `depends_on`. [12]

**Sidecar** — a container running alongside the main one for the pod's lifetime.
Since 1.28 a native sidecar is an init container with `restartPolicy: Always`.
[02, 12]

**Rolling update** — replacing pods gradually, bounded by `maxSurge` and
`maxUnavailable`, each new pod becoming Ready before an old one goes. [05]

**Graceful shutdown** — `preStop` plus `terminationGracePeriodSeconds`, so
in-flight requests finish before the process exits. [13]

**CRI** — the Container Runtime Interface. Why Kubernetes orchestrates
*containers*, not *Docker*. [01]

**Subresource** — a separately permissioned sub-path of a resource: `pods/log`,
`pods/exec`, `deployments/scale`. Granting `pods` does not grant them. [19]

**Impersonation** — `--as=<user>`, used to test another identity's permissions
without holding their credentials. [19]

---

## Tools

**kind** — Kubernetes IN Docker. Each node is a Docker container. [01]

**kubectl** — the CLI. An HTTP client for the API server. [02]

**kubeconfig** — clusters plus users plus contexts. `~/.kube/config`. [01]

**crictl** — the CRI equivalent of `docker images` / `docker ps`, used inside a
node. [08]

**Kustomize** — overlay-based manifest customisation, built into kubectl
(`-k`). [12]

**Helm** — templated, packaged, versioned Kubernetes applications. [12]

**cert-manager** — obtains and renews TLS certificates automatically. [20]

**External Secrets Operator / Sealed Secrets / SOPS / Vault** — ways to keep
real credentials out of git. [10]

**KEDA** — event-driven autoscaling, including scale-to-zero. [17]

**Cluster Autoscaler / Karpenter** — add and remove **nodes**. What the HPA
cannot do. [17]

**Operator** — a controller encoding operational knowledge for a specific
workload. For databases (CloudNativePG, Zalando, Crunchy), the right answer in
production. [11, 15]

**ingress2gateway** — automates the mechanical part of migrating Ingress
objects to the Gateway API. [20]
