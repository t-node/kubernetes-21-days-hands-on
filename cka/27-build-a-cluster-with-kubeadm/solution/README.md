# CKA 27 solution

## Challenge answers

### C1 - Add a node to a cluster you did not build

**On the new machine, as root:**

```bash
# 1. OS preparation (27.2)
swapoff -a && sed -i '/ swap / s/^/#/' /etc/fstab
modprobe overlay && modprobe br_netfilter
cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
cat > /etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

# 2. container runtime, with the matching cgroup driver
apt-get update && apt-get install -y containerd
mkdir -p /etc/containerd
containerd config default | sed 's/SystemdCgroup = false/SystemdCgroup = true/' \
  > /etc/containerd/config.toml
systemctl restart containerd && systemctl enable containerd

# 3. kubeadm, kubelet, kubectl -- at the CLUSTER's version, not the newest
apt-get install -y kubelet=1.31.4-* kubeadm=1.31.4-* kubectl=1.31.4-*
apt-mark hold kubelet kubeadm kubectl
```

**On the control plane:**

```bash
kubeadm token create --print-join-command
```

**Back on the new machine:**

```bash
kubeadm join <endpoint>:6443 --token <t> --discovery-token-ca-cert-hash sha256:<h>
```

**On the control plane:**

```bash
kubectl get nodes -w
```

**What to check at each stage if it fails:**

| Stage | Check |
|---|---|
| preflight | read the error -- it names the failing check. `swapon --show`, `sysctl net.bridge.bridge-nf-call-iptables`, `systemctl status containerd` |
| join hangs on discovery | can the machine reach the endpoint? `curl -k https://<endpoint>:6443/version`. Firewall on 6443 |
| join fails on the token | `kubeadm token list` on the control plane -- expired (27.4) |
| joined but `NotReady` | see C3 |
| joined at the wrong version | `kubectl get nodes` -- version skew ([CKA 12](../../12-cluster-maintenance/)); kubelet may be at most 3 minors below the API server, never above |

**The version pin in step 3 is the step people skip.** Installing "latest" onto a
1.31 cluster gives you a 1.33 kubelet, which is *ahead* of the API server and
therefore unsupported. `apt-mark hold` stops an unattended upgrade doing it later.

### C2 - The token expired

**1. One command:**

```bash
kubeadm token create --print-join-command
```

**2. By hand, three pieces (27.4):**

```bash
# the token
kubeadm token create
#   or generate one and register it:
TOKEN=$(kubeadm token generate)
kubeadm token create "$TOKEN" --ttl 2h --description "adding worker-04"

# the endpoint
kubectl -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' | grep controlPlaneEndpoint
#   or the API server address from any kubeconfig
kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}{"\n"}'

# the CA hash
openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt \
  | openssl rsa -pubin -outform der 2>/dev/null \
  | openssl dgst -sha256 -hex | sed 's/^.* //'
```

Assemble:

```bash
kubeadm join <endpoint> --token <token> --discovery-token-ca-cert-hash sha256:<hash>
```

**3. Why the hash is not a secret.**

It is a SHA-256 of the **public** key in `ca.crt` — a certificate you hand to
every client anyway. Publishing it reveals nothing; it is a fingerprint, exactly
like an SSH host key fingerprint.

**What goes wrong if you omit it:** the joining node has no way to verify that
the API server it is talking to is the right one. It would fetch the cluster's CA
from whatever answers the endpoint, trust it, and then present its bootstrap
token to it — **handing a valid credential to an impostor**, which can then use it
to join the real cluster.

`--discovery-token-unsafe-skip-ca-verification` does exactly that, and its name
is honest.

**4. `--ttl 0` means the token never expires.**

It exists for automation that cannot fetch a fresh token — an autoscaling group's
user-data, a bare-metal provisioning system, an image bake.

**Why it is usually a bad idea:** a bootstrap token is a credential that lets its
holder **join a node to your cluster**, and a node can then read every Secret
mounted into pods scheduled on it. A permanent token in a cloud-init script, a
Git repository or an AMI is a permanent way in.

If you need one, scope it: a short TTL refreshed by automation is better; failing
that, rotate deliberately (`kubeadm token delete`) and keep it out of anything
that gets copied.

### C3 - `NotReady`, four causes

**1. No CNI installed.**

```bash
kubectl describe node NODE | grep -i -A2 NetworkReady
#   -> NetworkPluginNotReady ... cni plugin not initialized
kubectl get pods -A | grep -Ei 'calico|cilium|flannel|weave'    # nothing
```
**Fix:** install one, matching the cluster's `--pod-network-cidr`
([CKA 22](../../22-pod-networking-and-cni/) C5).

**2. The CNI is installed but this node's config was never written.**

```bash
kubectl get pods -A -o wide | grep -E 'calico|flannel' | grep NODE   # is its pod there?
ssh NODE ls /etc/cni/net.d/                                          # empty
ssh NODE ls /opt/cni/bin/
kubectl -n kube-system logs <cni-pod-on-that-node>
```
**The tell is the same `NetworkReady=false` message as cause 1**, on a cluster
where other nodes are fine. Usually the CNI's DaemonSet pod is crash-looping on
that node, or a taint stopped it being scheduled there.
**Fix:** get the CNI pod running on that node; it writes the config on start.

**3. The kubelet is not running.**

```bash
kubectl describe node NODE | grep -A5 Conditions
#   -> "Kubelet stopped posting node status" / NodeStatusUnknown
ssh NODE systemctl status kubelet
ssh NODE journalctl -u kubelet -n 50 --no-pager
```
**Distinguishing signal: the node's conditions are `Unknown`, not `False`.** A
running kubelet reports `Ready=False` with a reason; a dead one reports nothing
and the node controller marks everything `Unknown` after ~40 seconds.
**Fix:** whatever the journal says — most often the cgroup driver mismatch (27.2),
a bad `/var/lib/kubelet/config.yaml`, or swap being back on after a reboot.

**4. The kubelet runs but cannot reach the API server.**

```bash
ssh NODE journalctl -u kubelet -n 50 | grep -iE "connection refused|x509|Unauthorized"
ssh NODE curl -k https://<endpoint>:6443/version
ssh NODE openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -dates
```
**Also `Unknown` conditions**, like cause 3 — but the kubelet is running. The
journal distinguishes them immediately: connection errors, or
`x509: certificate has expired` ([CKA 13](../../13-tls-in-kubernetes/)).
**Fix:** network/firewall on 6443, or renew the kubelet certificate.

**Which one `kubectl describe node` diagnoses alone: cause 1.** It states
`NetworkPluginNotReady` and `cni plugin not initialized` explicitly. Cause 2
produces the identical message and needs the node compared against its peers;
causes 3 and 4 produce `Unknown` conditions that say only "the kubelet stopped
posting status" — you must get onto the machine.

**So: `describe node` tells you whether the kubelet is talking to you.** If it is,
the problem is the CNI; if it is not, the problem is on the node.

### C4 - Rejoin a node cleanly

**1. What state the machine is in.**

**Completely unchanged, and still running.** `kubectl delete node` removes the
`Node` **object** from etcd; it does not contact the machine (27.5). So:

- the kubelet is running, with a valid client certificate
- containerd is running, with the workload containers still up
- `/etc/kubernetes/` is intact, including `kubelet.conf`
- the CNI config and its iptables rules are in place

And the interesting part: **the kubelet will re-register itself.** It still
authenticates as `system:node:<name>`, and the Node authorizer permits a node to
create its own Node object. Within a minute the node reappears in
`kubectl get nodes` — often before anyone notices it was deleted.

If it does *not* reappear, the workloads on it are now orphaned: running
containers no controller knows about, holding pod IPs
([CKA 22](../../22-pod-networking-and-cni/) IPAM) and serving no traffic, because
their endpoints went with the Node object.

**2. Why a plain `kubeadm join` fails.**

```
[ERROR FileAvailable--etc-kubernetes-pki-ca.crt]: /etc/kubernetes/pki/ca.crt already exists
[ERROR FileAvailable--etc-kubernetes-kubelet.conf]: /etc/kubernetes/kubelet.conf already exists
[ERROR Port-10250]: Port 10250 is in use
```

`kubeadm join` **refuses to overwrite an existing configuration.** That is
deliberate: joining a machine that already belongs to some cluster is almost
always a mistake, and silently reconfiguring it would be worse than failing.

**3. The correct sequence.**

```bash
# ON THE MACHINE
kubeadm reset -f

# the cleanup kubeadm reset does NOT do (27.5)
rm -rf /etc/cni/net.d
rm -rf /root/.kube "$HOME/.kube"
iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X
ipvsadm -C 2>/dev/null || true          # only if the cluster used ipvs mode

# ON THE CONTROL PLANE
kubectl get nodes                        # confirm it is really gone
kubeadm token create --print-join-command

# ON THE MACHINE
kubeadm join <endpoint> --token <t> --discovery-token-ca-cert-hash sha256:<h>
```

If the node had **not** already been deleted, the sequence starts with
`kubectl drain NODE --ignore-daemonsets --delete-emptydir-data` and
`kubectl delete node NODE` — draining first, so its pods are rescheduled rather
than killed.

**4. The leftover with the strangest symptoms: stale iptables rules.**

`kubeadm reset` prints a warning about them and people skip it. What happens:

The machine keeps every `KUBE-SVC-*` and `KUBE-SEP-*` chain from the *old*
cluster ([CKA 23](../../23-service-networking/)) — DNAT rules pointing ClusterIPs
at pod addresses that no longer exist. After rejoining, kube-proxy adds the *new*
cluster's rules alongside them.

**The symptoms are bizarre and intermittent:**

- a Service works from every node except this one
- traffic to a ClusterIP reaches a pod IP that is in no EndpointSlice
- connections hang rather than being refused, because the old rule matched and
  DNAT'd to an address nothing answers
- **`kubectl get endpoints` is correct**, which sends you looking in the wrong
  place entirely

And because kube-proxy only ever *adds* its own chains, a resync does not remove
the strays — restarting kube-proxy does not fix it.

The second-worst leftover is **`/etc/cni/net.d`**: the old CNI's config alongside
the new one, and **the first file alphabetically wins**
([CKA 22](../../22-pod-networking-and-cni/)). A `10-flannel.conflist` left behind
shadows a newly installed `10-calico.conflist`, so pods get addresses from the
wrong CIDR and cross-node traffic fails while the node reports `Ready`.

**Both are silent, both survive reboots, and both are one `rm -rf` away from not
happening.**

### C5 - Pick the flags

```bash
kubeadm init \
  --control-plane-endpoint "k8s.corp.example:6443" \
  --upload-certs \
  --pod-network-cidr=192.168.0.0/16 \
  --service-cidr=172.20.0.0/16 \
  --kubernetes-version=v1.31.4
```

| Flag | Why |
|---|---|
| **`--control-plane-endpoint`** | the load balancer name in front of the three control planes ([CKA 26](../../26-cluster-design-and-ha/) C4). **The one that cannot be added later.** |
| **`--upload-certs`** | stores the shared certificates in a Secret so `kubeadm join --control-plane` can fetch them; without it you copy `/etc/kubernetes/pki/` between nodes by hand |
| **`--pod-network-cidr=192.168.0.0/16`** | **Calico's default IP pool** -- matching it means no `IPPool` to configure ([CKA 22](../../22-pod-networking-and-cni/) C5) |
| **`--service-cidr=172.20.0.0/16`** | as required, and disjoint from the pod CIDR ([CKA 23](../../23-service-networking/), 23.4) |
| **`--kubernetes-version`** | pins the control plane rather than taking the newest, so the build is reproducible and matches the kubelet packages you pinned |

**Check both CIDRs before running anything** — not only against each other, but
against the corporate network the nodes sit on. A pod CIDR overlapping a real
subnet gives you a cluster that cannot reach part of your own infrastructure, and
it is not fixable afterwards.

**The flag that cannot be added later: `--control-plane-endpoint`.**

kubeadm writes the first node's own address into the cluster's kubeconfigs, the
`kubeadm-config` ConfigMap, and every kubelet's `kubelet.conf`. Adding the flag
afterwards means editing the ConfigMap, reissuing the API server certificate with
the new name in its SAN list ([CKA 13](../../13-tls-in-kubernetes/) C4),
rewriting every kubeconfig on every node, and restarting everything — **a rebuild
with extra steps.** `kubeadm join --control-plane` refuses until it is right.

**Set it even on a single-node cluster you only *might* grow.** A DNS name that
initially resolves to one node costs nothing and preserves the option.

`--upload-certs` is the runner-up: it can be redone later with
`kubeadm init phase upload-certs --upload-certs`, which prints a fresh
certificate key — so forgetting it is recoverable, unlike the endpoint.

---

## Files

| File | Purpose |
|---|---|
| `lab-up.sh` | two "machines" -- privileged `kindest/node` containers running systemd, with no cluster on them |
| `kubeadm-init.sh` | `kubeadm init`, printing each command first; ends at `NotReady` with CoreDNS `Pending` |
| `install-cni.sh` | `flannel` (from the internet) or `manual` (a hand-written bridge conflist plus routes) |
| `kubeadm-join.sh` | `join` -- token, independently recomputed CA hash, the resulting CSR and certificate; `reset` -- the full removal sequence |
| `kubectl-lab.sh` | run kubectl against the lab cluster from inside the control-plane node |
| `lab-down.sh` | remove the containers and the network |
| `verify.sh` | checks every claim in Part 4 |

---

## Why containers instead of VMs

The transcript builds this on VirtualBox VMs with Vagrant, which is the right way
to learn it and needs a machine that can run three VMs plus about forty minutes
of downloads.

**`lab-up.sh` uses privileged `kindest/node` containers running systemd instead —
precisely how kind builds its own nodes.** They have a real init system, real
containerd, a real kubelet, and `kubeadm init` genuinely runs. The image already
contains the control-plane images for its version, so nothing is downloaded.

**What is identical:** every kubeadm command, every file it produces, the
bootstrap token handshake, the CSR, the certificates, the `NotReady`-until-CNI
behaviour, and the reset sequence.

**What is not:** `--ignore-preflight-errors=all` is required, because a container
fails several preflight checks a VM would pass — swap accounting, kernel module
visibility, `/proc` entries owned by the host. **On a real machine you would fix
those failures rather than ignore them**, which is exactly what 27.2 is for, and
why Part B has you verify each prerequisite by hand first.

If you want the VM experience, the commands in `kubeadm-init.sh` and
`kubeadm-join.sh` transfer unchanged to a `multipass launch` or `vagrant up`
machine. Drop `--ignore-preflight-errors=all` and fix what preflight reports.

## If `kubeadm init` fails

Three places to look, in order:

```bash
docker exec kubeadm-cp journalctl -u kubelet --no-pager | tail -40
docker exec kubeadm-cp crictl ps -a
docker exec kubeadm-cp sh -c 'crictl logs $(crictl ps -a -q | head -1)'
```

**The kubelet journal is almost always the answer**, because `kubeadm init`
writes the static pod manifests and then waits for the kubelet to start them
([CKA 05](../../05-manual-scheduling-and-static-pods/)). If it hangs at
`[wait-control-plane]`, the manifests are on disk and the kubelet is failing to
run them — a cgroup driver mismatch (27.2), a missing image, or a container
runtime that is not running.

`crictl` is the right tool there for the same reason as
[CKA 02](../../02-container-runtimes-and-crictl/): there is no API server yet, so
`kubectl` cannot help.
