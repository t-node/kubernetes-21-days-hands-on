# CKA 22 solution

## Challenge answers

### C1 - Read an unfamiliar CNI config

**1. Three binaries, in list order:** `bridge`, then `portmap`, then
`bandwidth` — plus `host-local`, which `bridge` invokes itself for IPAM. So four
processes per pod creation, and the same four with `DEL` on deletion.

Order matters: each plugin receives the previous one's Result on stdin, so
`portmap` knows the address `bridge` assigned.

**2. `host-local` assigns the IP**, and the record is one file per address under
`/var/lib/cni/networks/mynet/` — the directory is named after the config's
`"name"`, not the bridge. Each file contains the container id holding it (22.5).

**3. `isGateway: true` gives the bridge itself an address** — the first usable
one in the subnet, `10.22.0.1` — so the bridge becomes the pods' default
gateway. In `ip` terms it is the difference between:

```bash
ip addr add 10.22.0.1/16 dev cni0        # isGateway: true does this
```

and a bridge with no address, which pods could reach each other through but
could not use as a router (21.5).

**4. Removing `ipMasq: true` removes the MASQUERADE rule** (21.6).

- **Still works:** pod to pod on this node, pod to pod on other nodes, pod to
  Service — everything inside the cluster, because those destinations have
  routes back to the pod CIDR.
- **Breaks:** anything outside the cluster. Packets leave with a `10.22.x.x`
  source and nothing on the internet or the corporate LAN can reply.

**Symptom: pods work perfectly with each other and cannot reach the internet.**
That is the specific signature of a missing masquerade rule.

**5. A `/16` per node is wrong** — it is 65,534 addresses on one machine, which
can never run more than a few hundred pods, and if every node uses the same
`/16` the pod CIDRs **overlap** and cross-node routing is impossible.

It should be **a `/24` per node carved out of a cluster-wide range**: cluster
`10.22.0.0/16`, node 1 gets `10.22.1.0/24`, node 2 `10.22.2.0/24`. That is what
`--pod-network-cidr` plus `--node-cidr-mask-size` produce, and it is what the
`via` routes in [CKA 21](../../21-linux-networking-foundations/) reflect.

### C2 - The node that ran out of IPs

**1. How.** `host-local` allocates from files on disk, and it releases an address
only when the plugin's `DEL` runs successfully (22.5). Every pod whose `DEL`
never ran — kubelet killed mid-delete, node powered off, containerd crash,
plugin binary missing at deletion time — **leaves its file behind forever**.
Those addresses are never reused. After enough churn, 254 addresses are consumed
by 11 live pods and ~240 ghosts.

**2. Confirm:**

```bash
# how many addresses are allocated?
ls /var/lib/cni/networks/*/ | grep -cE '^[0-9]+\.'

# how many pods actually run here?
kubectl get pods -A --field-selector spec.nodeName=<node> --no-headers | wc -l

# which allocations belong to no running container?
for f in /var/lib/cni/networks/*/10.*; do
  id=$(cat "$f")
  crictl ps -a -q | grep -q "${id:0:12}" || echo "STALE: $f -> $id"
done
```

**A large gap between those two counts is the diagnosis.**

**3. The fix:** delete the stale files.

```bash
rm /var/lib/cni/networks/<net>/10.244.3.42
```

**The check you must do first: confirm no running container holds that id.** The
loop above does it. Deleting a file for a *live* pod is much worse than the
original problem — the address becomes available for reallocation while still in
use, and you get two pods with the same IP, which produces intermittent traffic
going to the wrong place and is extremely hard to diagnose.

Safer still: **drain the node, delete the whole directory, restart the kubelet.**
With no pods running, nothing can be misallocated.

**4. Cause and prevention.** The root cause is `DEL` not running or failing.
Prevention:

- **drain nodes before shutting them down** ([CKA 12](../../12-cluster-maintenance/)) — a
  graceful eviction runs `DEL` for every pod
- **alert on the ratio** of IPAM files to running pods; it is a one-line check
  and it catches the problem months before it bites
- **prefer a CNI whose IPAM is not node-local files** — Calico and Cilium track
  allocations in the datastore and can reconcile them against live pods, which is
  a large part of why they scale better

### C3 - Overlay or routed

**Four independent pieces of evidence:**

**1. Encapsulation interfaces.**
```bash
ip -d link show type vxlan          # flannel.1, vxlan.calico
ip link show tunl0                  # Calico IPIP
ip -d link show type wireguard      # encrypted overlay
```
Any of these present means encapsulation.

**2. The routing table.**
```bash
ip route | grep <pod-cidr>
```
`10.244.2.0/24 via 172.18.0.3 dev eth0` is **routed** — a next hop on the real
network. `10.244.2.0/24 dev flannel.1 onlink` is an **overlay** — the next hop is
a tunnel device.

**3. MTU.**
```bash
ip -br link | awk '{print $1, $NF}'
kubectl exec POD -- ip link show eth0
```
1500 is routed. **1450 (VXLAN) or 1480 (IPIP) is encapsulated** — the missing
bytes are the header.

**4. The packet on the wire.**
```bash
tcpdump -i eth0 -n 'udp port 8472' -c 5      # VXLAN
tcpdump -i eth0 -n 'proto 4' -c 5            # IPIP
```
Traffic on UDP 8472 while pods are talking is VXLAN, definitively.

**The practical differences:**

**(a) MTU.** On an overlay the pod's usable MTU is smaller than the underlying
network's. Get it wrong — a pod believing it has 1500 on a path that carries
1450 — and small packets work while large ones are silently dropped. **The
classic symptom is a TCP connection that establishes and then hangs on the first
large response**: ping works, DNS works, `curl` of a small page works, and a TLS
handshake or a big JSON payload times out. Path MTU discovery is supposed to fix
this and is frequently broken by firewalls dropping ICMP.

**(b) `tcpdump`.** On a routed cluster you capture on `eth0` and see pod IPs
directly. **On an overlay you see node-to-node UDP with the real packet inside**,
so you must either capture on the tunnel device (`tcpdump -i flannel.1`) or ask
tcpdump to decode the encapsulation (`-T vxlan`). Capturing on the wrong
interface and concluding "the traffic never left" is a standard hour lost.

**(c) Firewalls.** Routed clusters need the **pod CIDR** allowed between nodes.
Overlays need the **encapsulation port** allowed — UDP 8472 for VXLAN, IP
protocol 4 for IPIP — and IPIP in particular is often blocked by default in cloud
security groups, because it is a protocol rather than a port and rules tend to be
written in terms of TCP and UDP. **A cluster where pods on the same node work and
cross-node traffic fails, on a fresh cloud install, is usually this.**

### C4 - Order of operations

**The order:**

```
b.  the scheduler sets spec.nodeName
a.  the kubelet calls RunPodSandbox
d.  containerd creates the network namespace
c.  containerd runs /opt/cni/bin/<type> with CNI_COMMAND=ADD
e.  the plugin returns a Result containing the pod IP
f.  the kubelet starts the application containers
```

Two things worth noticing in that list. **The scheduler is finished before any of
this starts** — it decided based on the node being `Ready` at that moment, which
is why a node that loses its CNI still receives pods. And **the application
containers start last**, after the network exists, which is why a CNI failure
looks like `ContainerCreating` and never like a crashing application.

**Where each error lands:**

| Error | Fails at | Why |
|---|---|---|
| `cni plugin not initialized` | **c** | containerd has no usable config in `/etc/cni/net.d`, so there is nothing to invoke. Reported by the kubelet as `NetworkReady=false` |
| `no IP addresses available` | **e** | the plugin ran and IPAM had nothing to give (C2). The plugin returns an error instead of a Result |
| `ImagePullBackOff` | **f** | networking succeeded completely; the pod has an IP. This is a registry problem ([CKA 17](../../17-image-security-and-security-contexts/)) |

**The third one is the useful discrimination.** `ImagePullBackOff` proves the
sandbox was created, which proves the CNI worked — so any time you see it, CNI
is off the list of suspects entirely. Conversely `FailedCreatePodSandBox` means
the failure was at c, d or e, and the image is irrelevant.

### C5 - Install a CNI on a bare cluster

**1. Why CoreDNS specifically is `Pending`.**

The other control-plane components — the API server, scheduler, controller
manager, etcd — are **static pods with `hostNetwork: true`**
([CKA 05](../../05-manual-scheduling-and-static-pods/)). They use the node's
network namespace, need no pod IP, and therefore need no CNI. They start on a
cluster with no networking at all.

**CoreDNS is an ordinary Deployment that needs a pod IP.** No CNI means no
sandbox, so it stays `Pending`, and the node is `NotReady` which keeps the
scheduler from placing it anyway.

**CoreDNS `Pending` on a fresh `kubeadm init` is the expected state, not a
fault** — it is the cluster telling you the CNI step has not been done.
`kubeadm init`'s own output says as much.

**2. The sequence:**

```bash
# 1. install -- one manifest, whichever CNI you chose
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.2/manifests/calico.yaml

# 2. wait for its DaemonSet, not for the nodes
kubectl -n kube-system rollout status daemonset/calico-node --timeout=300s

# 3. now the nodes
kubectl wait --for=condition=Ready nodes --all --timeout=300s

# 4. and CoreDNS unblocks on its own
kubectl -n kube-system get pods -l k8s-app=kube-dns

# 5. prove it end to end
kubectl run t1 --image=busybox:1.36 -- sleep 3600
kubectl run t2 --image=busybox:1.36 -- sleep 3600
kubectl exec t1 -- ping -c2 $(kubectl get pod t2 -o jsonpath='{.status.podIP}')
kubectl exec t1 -- nslookup kubernetes.default
```

**Step 5 matters.** `Ready` nodes mean the kubelet is satisfied; only traffic
proves the four requirements of 22.1 are met — and the same principle as
[CKA 18](../../18-network-policies/), where a policy that exists is not a policy
that works.

**3. What must match: the pod CIDR.**

`kubeadm init --pod-network-cidr=10.244.0.0/16` writes that range into the
controller manager's `--cluster-cidr`, and the controller manager hands each node
a `/24` out of it as `spec.podCIDR`. **The CNI must allocate from the same
range.** Calico's default IP pool is `192.168.0.0/16`; Flannel's manifest expects
`10.244.0.0/16`.

Get it wrong and you produce a cluster that *looks* fine: nodes go `Ready`, pods
get addresses, pods on one node talk to each other — and **cross-node traffic
fails**, because the `via` routes are for a range the pods are not actually in.

```bash
kubectl cluster-info dump | grep -m1 cluster-cidr
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.podCIDR}{"\n"}{end}'
```

This is exactly why [CKA 18](../../18-network-policies/)'s
`kind-calico.yaml` sets `podSubnet: 192.168.0.0/16` — matching kind's setting to
Calico's default rather than configuring an IPPool by hand.

**4. Two checks that are not `kubectl get nodes`:**

```bash
# a. the config the CNI wrote onto the node
docker exec <node> ls -la /etc/cni/net.d/
docker exec <node> cat /etc/cni/net.d/*.conflist

# b. real traffic between two pods on DIFFERENT nodes
kubectl get pods -o wide          # confirm they are on different nodes
kubectl exec t1 -- ping -c2 <t2-pod-ip>
```

**(a) proves the CNI installed itself**; a DaemonSet can be `Running` and still
have failed to write its config, which leaves nodes `NotReady` with a `Running`
CNI pod — a genuinely confusing state.

**(b) proves requirement 3**, the one that a single-node test can never exercise
and that is broken by exactly the CIDR mismatch in question 3.

---

## Files

| File | Purpose |
|---|---|
| `run-in-node.sh` | copy a script into a kind node and run it there |
| `cni-explore.sh` | binaries, config, plugin chain, IPAM state, runtime config, overlay check, node identity, ports |
| `cni-by-hand.sh` | `add` / `del` -- invoke a CNI plugin exactly as containerd does |
| `break-cni.sh` | `break` / `fix` -- take `/etc/cni/net.d` away and restore it |
| `01-two-pods.yaml` | two pods on different nodes, to prove requirement 4 |
| `verify.sh` | checks the installation and one real allocation end to end |

---

## On `cni-by-hand.sh`

It is the assignment's centrepiece and it is worth understanding why it works at
all.

**A CNI plugin has no dependency on Kubernetes.** It is a binary that reads five
environment variables and a JSON document, manipulates a network namespace, and
prints a result. Containerd's involvement is entirely: create the namespace, set
the variables, pipe in the config, run the binary, parse the output.

So you can do all of that from a shell — and when a CNI is misbehaving in
production, **that is precisely what you should do**, because it removes the
kubelet, the runtime and the API server from the picture and leaves you with one
process and its exit code.

The script picks `bridge` if the node has it and falls back to `ptp`, because
kind ships a subset of the reference plugins and the exact set varies by version.
Both create a veth pair; `bridge` also attaches one end to a Linux bridge, while
`ptp` is point-to-point with a route instead. If you want to see the difference,
run the script, then:

```bash
docker exec devops-worker ip -br link show type bridge
docker exec devops-worker ip -n cnidemo route
```

`10.99.0.0/24` is used deliberately — it overlaps neither the pod CIDR
(`10.244.0.0/16`) nor the kind Docker network (`172.18.0.0/16`), so nothing it
creates can collide with the cluster.

## On `break-cni.sh`

The asymmetry it demonstrates is the thing to remember: **removing the CNI
configuration does not disturb a single running pod.**

Pod networking is configured once, at sandbox creation, and never revisited. A
pod that has an interface, an address and routes keeps them whatever happens to
`/etc/cni/net.d` afterwards. What breaks is the *next* sandbox — and the node
going `NotReady`, which stops the scheduler sending more work.

That is why the recovery is "restore the file and wait" rather than anything more
dramatic. It is also why this failure is often noticed late: a node can sit with
a broken CNI for hours, serving traffic perfectly, until something restarts.
