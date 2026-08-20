# CKA 27 — Build a Cluster with kubeadm

**Time:** 110-140 minutes
**Prerequisites:** [CKA 01](../01-control-plane-components/), [CKA 05](../05-manual-scheduling-and-static-pods/), [CKA 13](../13-tls-in-kubernetes/), [CKA 22](../22-pod-networking-and-cni/), [CKA 26](../26-cluster-design-and-ha/)
**Source lectures:** 244, 246, 247, 249

Every cluster in this repo so far was created by `kind` in ninety seconds. This
assignment does it the long way — **`kubeadm init`, a CNI, `kubeadm join`** — and
then takes the result apart to see what those three commands actually produced.

---

## Part 1 - Concepts

### 27.1 What kubeadm is, and is not

**kubeadm bootstraps a conformant control plane.** It does not install a
container runtime, does not install a CNI, does not provision machines, and does
not manage the cluster afterwards.

| kubeadm does | You do |
|---|---|
| generate the CA and all certificates | provision the machines |
| write the static pod manifests | install containerd |
| start the kubelet against them | install a CNI |
| create the bootstrap token | configure the OS -- swap, sysctls, modules |
| install CoreDNS and kube-proxy | everything after day 1 |

That division is the whole reason a fresh `kubeadm init` gives you a `NotReady`
node and a `Pending` CoreDNS ([CKA 22](../22-pod-networking-and-cni/) C5) — the
control plane is complete and pod networking has not been chosen yet.

### 27.2 The prerequisites, and why each one exists

Before `kubeadm init` will run:

| Requirement | Why |
|---|---|
| **swap off** | the scheduler's accounting assumes memory limits are real; swap makes them a lie |
| **`br_netfilter` loaded** | so bridged traffic traverses iptables -- without it, kube-proxy's rules never see pod traffic |
| **`net.bridge.bridge-nf-call-iptables = 1`** | the same thing, switched on |
| **`net.ipv4.ip_forward = 1`** | packets must cross between interfaces ([CKA 21](../21-linux-networking-foundations/)) |
| **unique hostname, MAC and `machine-id`** | cloned VMs otherwise collide ([CKA 22](../22-pod-networking-and-cni/)) |
| **ports open** | 6443, 10250, 2379-2380, 10257, 10259 ([CKA 22](../22-pod-networking-and-cni/)) |
| **a container runtime with the right cgroup driver** | see below |

```bash
swapoff -a && sed -i '/ swap / s/^/#/' /etc/fstab
modprobe br_netfilter
cat > /etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system
```

**The cgroup driver is the classic install failure.** The kubelet and the
container runtime must agree, and on any systemd distribution both must use
`systemd`:

```bash
ps -p 1 -o comm=          # systemd -> use the systemd driver
mkdir -p /etc/containerd
containerd config default | sed 's/SystemdCgroup = false/SystemdCgroup = true/' \
  > /etc/containerd/config.toml
systemctl restart containerd
```

**Since 1.22 the kubelet defaults to `systemd`**, so only containerd needs
changing. A mismatch produces a kubelet that starts, fails to manage cgroups, and
reports pods as unhealthy for reasons that look like anything but a cgroup
problem.

### 27.3 `kubeadm init` is a sequence of phases

```bash
kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --apiserver-advertise-address=192.168.1.10
```

Underneath, it runs an ordered list you can see and run individually:

```bash
kubeadm init phase --help
```

| Phase | Produces |
|---|---|
| `preflight` | the checks from 27.2 |
| `certs` | the two CAs and every leaf certificate ([CKA 13](../13-tls-in-kubernetes/)) |
| `kubeconfig` | `admin.conf`, `kubelet.conf`, `scheduler.conf`, `controller-manager.conf` |
| `control-plane` | the static pod manifests in `/etc/kubernetes/manifests` |
| `etcd` | etcd's static pod manifest |
| `kubelet-start` | writes the kubelet config and starts it |
| `upload-config` | the **`kubeadm-config` ConfigMap** -- how joins learn the settings |
| `upload-certs` | (with `--upload-certs`) certificates in a Secret, for control-plane joins |
| `mark-control-plane` | the label and the `NoSchedule` taint |
| `bootstrap-token` | the join token and its RBAC |
| `addon` | CoreDNS and kube-proxy |

**Being able to run one phase is the point.** `kubeadm init phase certs apiserver`
reissues one certificate ([CKA 13](../13-tls-in-kubernetes/) C4); `kubeadm init
phase control-plane apiserver` regenerates a static pod manifest you have
mangled. Both are exam-shaped repairs.

The two flags that matter most:

- **`--pod-network-cidr`** must match what the CNI is configured with
  ([CKA 22](../22-pod-networking-and-cni/) C5). It is written into the controller
  manager's `--cluster-cidr`, from which each node gets a `/24`.
- **`--control-plane-endpoint`** must be set **now** if the cluster might ever
  become HA ([CKA 26](../26-cluster-design-and-ha/) C4). Adding it later is a
  rebuild.

### 27.4 Joining is a bootstrap-token handshake

```bash
kubeadm join 192.168.1.10:6443 \
  --token abcdef.0123456789abcdef \
  --discovery-token-ca-cert-hash sha256:1234...
```

Three parts, and each answers a different trust question:

| Part | Answers |
|---|---|
| the **endpoint** | where is the API server |
| the **token** | *the cluster trusts me* -- it authenticates the joining node |
| the **CA cert hash** | *I trust the cluster* -- it verifies the API server's CA |

**The hash is what stops a joining node handing its credentials to an impostor.**
Skipping it with `--discovery-token-unsafe-skip-ca-verification` works and is
named accurately.

Tokens **expire after 24 hours by default**, which is the single most common
"I cannot add a node" problem:

```bash
kubeadm token list
kubeadm token create --print-join-command      # prints the whole command, hash included
```

**`--print-join-command` is the answer to the exam task.** Recompute the hash by
hand only if you must:

```bash
openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt \
  | openssl rsa -pubin -outform der 2>/dev/null \
  | openssl dgst -sha256 -hex | sed 's/^.* //'
```

What actually happens: the token authenticates the node as
`system:bootstrap:<id>`, which has just enough RBAC to submit a
**CertificateSigningRequest** ([CKA 15](../15-certificates-api-and-authorization/)).
The CSR is auto-approved, the kubelet gets a client certificate with
`CN=system:node:<hostname>` and `O=system:nodes`
([CKA 13](../13-tls-in-kubernetes/)), and from then on the node authenticates as
itself. **The token is used once and never again.**

### 27.5 `kubeadm reset` undoes it, incompletely

```bash
kubeadm reset -f
```

It stops the kubelet, removes `/etc/kubernetes`, deletes etcd's data, and — on a
control-plane node — removes itself from the etcd member list.

**What it leaves behind, and you must clean up:**

```bash
rm -rf /etc/cni/net.d          # the CNI config (CKA 22)
iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X
ipvsadm -C                     # if the cluster used ipvs mode
rm -rf $HOME/.kube
```

**Stale iptables rules are the reason a re-joined node behaves strangely.**
kubeadm says so in its output and people skip it.

And from the other side, deleting a node is two operations:

```bash
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
kubectl delete node <node>
```

**`kubectl delete node` does not touch the machine.** The kubelet keeps running
and will re-register if it still has valid credentials. `kubeadm reset` on the
machine is what actually removes it.

---

## Part 2 - Hands-on lab

Two halves. **Part A works on the cluster you already have** and is where most of
the exam-relevant knowledge is. **Part B builds a cluster from nothing**, which
is the part worth doing once.

### Part A — dissect the kubeadm cluster you already have

Your `devops` cluster was built by kind, which uses kubeadm underneath. Every
artefact from 27.3 is on it.

```bash
kubectl config use-context kind-devops
CP=devops-control-plane
```

**The phases, and what each left behind:**

```bash
docker exec $CP kubeadm init phase --help | sed -n '/Available Commands/,/^$/p'
docker exec $CP ls -1 /etc/kubernetes/
docker exec $CP ls -1 /etc/kubernetes/manifests/
docker exec $CP ls -1 /etc/kubernetes/pki/ | head
```

Four `.conf` files, four static pod manifests, and the certificate tree from
[CKA 13](../13-tls-in-kubernetes/). **Every one is the output of a named phase.**

**The config that joins read:**

```bash
kubectl -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}'
```

```yaml
kubernetesVersion: v1.31.4
controlPlaneEndpoint: devops-control-plane:6443
networking:
  podSubnet: 10.244.0.0/16
  serviceSubnet: 10.96.0.0/16
```

**This is how `kubeadm join` learns the cluster's settings** — the joining node
fetches it rather than being told. Note `controlPlaneEndpoint` is present, which
is what makes an HA join possible at all
([CKA 26](../26-cluster-design-and-ha/) C4).

**The bootstrap tokens:**

```bash
docker exec $CP kubeadm token list
kubectl -n kube-system get secrets --field-selector type=bootstrap.kubernetes.io/token
```

Probably empty or expired — kind's tokens are 24-hour like everyone's. Make one:

```bash
docker exec $CP kubeadm token create --print-join-command
```

**That single command is the answer to "add a node to this cluster"** on the
exam. Verify the hash it printed:

```bash
docker exec $CP sh -c 'openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt \
  | openssl rsa -pubin -outform der 2>/dev/null \
  | openssl dgst -sha256 -hex | sed "s/^.* //"'
```

**The same hex string.** It is a hash of the CA's public key — nothing secret, and
exactly what a joining node needs to recognise the right cluster (27.4).

**How the existing nodes authenticate:**

```bash
docker exec devops-worker sh -c \
  'openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -subject'
```

```
subject=O = system:nodes, CN = system:node:devops-worker
```

**That certificate was issued by a CSR during the join** (27.4), and it is what
the Node authorizer keys off ([CKA 13](../13-tls-in-kubernetes/), 13.6).

**And the check every kubeadm cluster should be running:**

```bash
docker exec $CP kubeadm certs check-expiration | head -12
docker exec $CP kubeadm upgrade plan 2>&1 | head -20
```

### Part B — build one from nothing

```bash
bash solution/lab-up.sh
```

It creates **two machines with no cluster on them** — Docker containers from the
`kindest/node` image, running systemd, privileged. That is exactly how kind
builds nodes; the difference is that **you** run kubeadm.

Prove they are empty:

```bash
docker exec kubeadm-cp ls /etc/kubernetes
docker exec kubeadm-cp crictl ps
docker exec kubeadm-cp systemctl is-active kubelet
```

```
ls: cannot access '/etc/kubernetes': No such file or directory
CONTAINER  IMAGE  ...   (empty)
inactive
```

**Check the prerequisites from 27.2** — `lab-up.sh` set them, and you should
confirm rather than trust:

```bash
docker exec kubeadm-cp sh -c 'sysctl net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables'
docker exec kubeadm-cp sh -c 'lsmod | grep br_netfilter'
docker exec kubeadm-cp sh -c 'ps -p 1 -o comm='
docker exec kubeadm-cp sh -c 'grep -B2 SystemdCgroup /etc/containerd/config.toml | head -4'
```

**`ps -p 1` says `systemd`, so the cgroup driver must be `systemd`** on both the
kubelet and containerd (27.2). Since 1.22 the kubelet defaults to it; check that
containerd agrees.

#### Initialise the control plane

```bash
bash solution/kubeadm-init.sh
```

It prints each command before running it. Watch for:

**Section 1** — the phase list from 27.3. Read it *before* the init runs, so the
output afterwards is recognisable.

**Section 3** — `kubeadm init` itself, about a minute of output. The important
lines are near the end:

```
Your Kubernetes control-plane has initialized successfully!
...
kubeadm join 172.19.0.2:6443 --token abcdef.0123456789abcdef \
    --discovery-token-ca-cert-hash sha256:1234...
```

**Section 5** — the state it leaves you in:

```
NAME         STATUS     ROLES           AGE   VERSION
kubeadm-cp   NotReady   control-plane   30s   v1.31.4

coredns-...                0/1   Pending
etcd-...                   1/1   Running
kube-apiserver-...         1/1   Running
kube-controller-manager-   1/1   Running
kube-proxy-...             1/1   Running
kube-scheduler-...         1/1   Running
```

**`NotReady` with CoreDNS `Pending` is the correct outcome** (27.1). Five
control-plane components are running; nothing has provided pod networking. Prove
it is the CNI and not something else:

```bash
bash solution/kubectl-lab.sh describe node kubeadm-cp | grep -i -A2 "NetworkReady"
docker exec kubeadm-cp ls /etc/cni/net.d
```

```
NetworkPluginNotReady message:Network plugin returns error: cni plugin not initialized
```

**The exact message from [CKA 22](../22-pod-networking-and-cni/)**, reached from
the other direction — you have now built the state that assignment broke on
purpose.

Look at what the phases produced:

```bash
docker exec kubeadm-cp ls -1 /etc/kubernetes/manifests/
docker exec kubeadm-cp ls -1 /etc/kubernetes/pki/
docker exec kubeadm-cp openssl x509 -in /etc/kubernetes/pki/ca.crt -noout -subject -dates
bash solution/kubectl-lab.sh -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}'
```

**A CA you created two minutes ago**, and the same `kubeadm-config` ConfigMap you
read in Part A.

#### Install a CNI

```bash
bash solution/install-cni.sh
```

or, with no internet and using only what
[CKA 22](../22-pod-networking-and-cni/) taught:

```bash
bash solution/install-cni.sh manual
```

The `manual` mode writes a `bridge` conflist per node using **that node's
`spec.podCIDR`**, and adds a route to the other node's CIDR — the two things a
CNI plugin does, done by hand
([CKA 21](../21-linux-networking-foundations/), [CKA 22](../22-pod-networking-and-cni/)).

```bash
bash solution/kubectl-lab.sh get nodes
bash solution/kubectl-lab.sh -n kube-system get pods
```

**`Ready`, and CoreDNS running.** One CNI turned a complete control plane into a
usable cluster.

#### Join the worker

```bash
bash solution/kubeadm-join.sh
```

Five sections, and section 3 is the one to read: **the CA hash from the join
command, recomputed independently from `ca.crt`.** They match, because the hash
is a fingerprint of the public key and nothing more (27.4).

Section 5 shows the result:

```bash
bash solution/kubectl-lab.sh get nodes -o wide
bash solution/kubectl-lab.sh get csr
docker exec kubeadm-wk sh -c \
  'openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -subject'
```

```
subject=O = system:nodes, CN = system:node:kubeadm-wk
```

**A CSR was submitted, auto-approved and signed** — the bootstrap handshake from
27.4, visible as objects.

Run something on it:

```bash
bash solution/kubectl-lab.sh create deployment web --image=nginx:alpine --replicas=3
bash solution/kubectl-lab.sh rollout status deployment/web --timeout=120s
bash solution/kubectl-lab.sh get pods -o wide
```

#### Remove the node again

```bash
bash solution/kubeadm-join.sh reset
```

Watch the order (27.5): **drain, delete the Node object, then `kubeadm reset` on
the machine** — followed by the cleanup `kubeadm reset` does *not* do. Note in
section 2 that deleting the Node object left the machine entirely untouched.

### Cleanup

```bash
bash solution/lab-down.sh
docker ps --filter "name=kubeadm-"
kubectl config use-context kind-devops
```

---

## Part 3 - Challenges

### C1 - Add a node to a cluster you did not build

You are given `kubectl` access and SSH to a fresh machine. Write the complete
sequence, from OS preparation to the node showing `Ready`, and say what you would
check at each stage if it did not work.

### C2 - The token expired

`kubeadm token list` is empty and you need to add a node.

1. Give the one command that solves it.
2. Reconstruct the join command by hand, without that command — token, endpoint
   and hash.
3. Why is the hash not a secret, and what would go wrong if you omitted it?
4. What is a TTL of `0` for, and why is it usually a bad idea?

### C3 - `NotReady`, four causes

A newly joined node stays `NotReady`. For each cause, give the confirming command
and the fix:

1. No CNI installed.
2. The CNI is installed but this node's config was never written.
3. The kubelet is not running.
4. The kubelet is running but cannot reach the API server.

Which one does `kubectl describe node` diagnose on its own?

### C4 - Rejoin a node cleanly

A worker was removed with `kubectl delete node` only — nobody touched the
machine. It must now rejoin.

1. What state is the machine in, and what is it still doing?
2. Why will a plain `kubeadm join` fail?
3. Give the correct sequence.
4. Which leftover causes the strangest symptoms if skipped, and what do they look
   like?

### C5 - Pick the flags

Write the `kubeadm init` command for a cluster that will eventually have three
control-plane nodes behind `k8s.corp.example`, use Calico with its default IP
pool, and reserve `172.20.0.0/16` for Services. Justify every flag, and name the
one that cannot be added later.

---

## Part 4 - Verify

```bash
bash solution/verify.sh
```

Run it after Part B. It checks that both machines exist and are running systemd;
that the control plane has all four static pod manifests and both CAs; that
`kubeadm-config` records the pod CIDR you passed; that both nodes are `Ready`
with a `spec.podCIDR`; that the worker's kubelet certificate has
`CN=system:node:<name>` and `O=system:nodes`; and that a Deployment schedules
across the cluster.

---

## Part 5 - Exam notes

**Fast paths**

```bash
# prepare a machine (27.2)
swapoff -a && sed -i '/ swap / s/^/#/' /etc/fstab
modprobe br_netfilter
echo 'net.bridge.bridge-nf-call-iptables=1' > /etc/sysctl.d/k8s.conf
echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.d/k8s.conf
sysctl --system

# init
kubeadm init --pod-network-cidr=10.244.0.0/16 --control-plane-endpoint=k8s.example:6443
mkdir -p ~/.kube && cp -i /etc/kubernetes/admin.conf ~/.kube/config && chown $(id -u):$(id -g) ~/.kube/config

# the join command, always
kubeadm token create --print-join-command
kubeadm token list

# one phase at a time (27.3)
kubeadm init phase --help
kubeadm init phase certs apiserver
kubeadm init phase control-plane apiserver
kubeadm init phase kubeconfig all

# what does this cluster think it is?
kubectl -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}'
kubeadm config print init-defaults
kubeadm upgrade plan
kubeadm certs check-expiration

# remove a node (27.5)
kubectl drain NODE --ignore-daemonsets --delete-emptydir-data
kubectl delete node NODE
#   ...then ON the machine:
kubeadm reset -f
rm -rf /etc/cni/net.d && iptables -F && iptables -t nat -F && iptables -X
```

**Traps**

- **kubeadm does not install a CNI.** `NotReady` plus `Pending` CoreDNS after
  `init` is the expected state, not a fault.
- **`--pod-network-cidr` must match the CNI's configuration**, or cross-node pod
  traffic fails while everything looks healthy.
- **`--control-plane-endpoint` cannot be added later.** Set it if HA is ever
  possible.
- **Tokens expire in 24 hours.** `kubeadm token create --print-join-command`.
- **The cgroup driver must match** between the kubelet and the runtime; on
  systemd, both `systemd`.
- **`kubectl delete node` does not touch the machine.** `kubeadm reset` does.
- **`kubeadm reset` leaves `/etc/cni/net.d` and iptables rules behind.** Clean
  them or the rejoined node misbehaves.
- **`kubeadm init phase X` reruns one step** — the repair tool for a mangled
  certificate or manifest.
- **Swap must be off**, or the kubelet refuses to start (unless explicitly
  permitted).
- **The join hash is public.** It is a fingerprint of `ca.crt`'s public key.
- **The kubelet's certificate is `CN=system:node:<hostname>`,
  `O=system:nodes`** — issued by a CSR during the join.

---

**Previous:** [CKA 26 — Cluster Design and High Availability](../26-cluster-design-and-ha/)
**Next: CKA 28 — Helm** *(not yet built — see [CURRICULUM.md](../CURRICULUM.md))*
