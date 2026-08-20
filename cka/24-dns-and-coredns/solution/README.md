# CKA 24 solution

## Challenge answers

### C1 - Write the names

**1.** `payments.fin.svc.cluster.local`

**2.** From a pod **in `fin`**: `payments` — its own namespace is the first
search suffix. From a pod **in `default`**: `payments.fin` at minimum, because
`default`'s search list starts with `default.svc.cluster.local`, which does not
contain it. `payments.fin.svc` and the FQDN also work.

**3.** `payments-headless.fin.svc.cluster.local` — a headless Service returns one
A record per **ready** endpoint (24.1). Not the normal Service, which returns one
ClusterIP.

**4.** `payments-1.payments-headless.fin.svc.cluster.local`

StatefulSet ordinals start at **0**, so the *second* replica is `payments-1`. The
name is `<pod>.<serviceName>.<ns>.svc.cluster.local`, and `serviceName` on the
StatefulSet must be `payments-headless` for it to exist.

**5.** `_grpc._tcp.payments.fin.svc.cluster.local`

The label is the **port name**, not the protocol name — `grpc` because that is
what the Service calls it. An unnamed port produces no SRV record at all.

**6.** `10-244-3-17.fin.pod.cluster.local`

Two reasons you probably cannot use it: **pod records are disabled by default**
(`pods disabled` or `insecure` in the Corefile), and more fundamentally **you had
to know the IP to build the name**, so it answers a question you have already
answered. Note also it is under `.pod.` and not `.svc.`, so no search suffix
will find it — the FQDN is mandatory.

### C2 - Five DNS failures

**1. `connection refused`, instantly**

**CoreDNS is not running**, so the `kube-dns` Service has no endpoints and
kube-proxy wrote a REJECT rule ([CKA 23](../../23-service-networking/)).

```bash
kubectl -n kube-system get pods -l k8s-app=kube-dns
kubectl -n kube-system get endpoints kube-dns          # <none>
```

**2. The same query times out**

Endpoints exist and nothing answered. The DNS *server* is fine; the *path* is
not.

```bash
kubectl -n kube-system get endpoints kube-dns          # populated
kubectl -n kube-system get pods -l k8s-app=kube-proxy -o wide
kubectl get netpol -A
kubectl exec POD -- dig @<coredns-pod-ip> web.default.svc.cluster.local
```

**Querying a CoreDNS pod IP directly is the discriminator.** If that works and
the ClusterIP does not, kube-proxy is the problem. If neither works, a
NetworkPolicy is dropping UDP 53 — which is the single most common cause of this
symptom in a cluster that has just adopted policies
([CKA 18](../../18-network-policies/)).

**3. FQDN resolves; the short name does not**

**The search list is wrong or absent.**

```bash
kubectl exec POD -- cat /etc/resolv.conf
```

Expect `search <ns>.svc.cluster.local svc.cluster.local cluster.local` and
`options ndots:5`. Causes: `dnsPolicy: None` with an incomplete `dnsConfig`, an
`ndots` low enough that the short name is tried as-is first (24.5), or a
`dnsConfig.searches` that replaced the generated list.

**A second, sneakier cause: BusyBox.** Its `nslookup` ignores the search list
entirely, so the name resolves fine and the tool says otherwise. Confirm with
`dig +search` or from a `dnsutils` pod before believing it.

**4. Only the `hostNetwork` pod fails**

**`dnsPolicy` defaults to `Default` for host-networked pods** (24.5), so it is
using the node's resolver.

```bash
kubectl get pod POD -o jsonpath='{.spec.hostNetwork} {.spec.dnsPolicy}{"\n"}'
kubectl exec POD -- cat /etc/resolv.conf
```

Note the field will **read `ClusterFirst`** and still not behave that way. The
fix is `dnsPolicy: ClusterFirstWithHostNet`.

**5. `Loop ... detected`**

**The node's `/etc/resolv.conf` forwards back to CoreDNS**, so
`forward . /etc/resolv.conf` creates an infinite loop. The `loop` plugin detects
it at startup and exits deliberately (24.3).

```bash
kubectl -n kube-system logs -l k8s-app=kube-dns | grep -i loop
docker exec <node> cat /etc/resolv.conf       # look for 127.0.0.53
```

Almost always **systemd-resolved**: the node's resolver is a local stub at
`127.0.0.53` which forwards to whatever it was told — and on a Kubernetes node
that can end up being CoreDNS.

Three fixes, in order of preference: point the kubelet at the real upstream file
with `--resolv-conf=/run/systemd/resolve/resolv.conf`; or replace
`forward . /etc/resolv.conf` with an explicit upstream such as
`forward . 8.8.8.8`; or fix the node's resolver configuration. **Removing the
`loop` plugin is not a fix** — it converts a fast, loud failure into a slow
resource leak.

### C3 - Point at a corporate resolver

**1. The change — a second server block, not an edit to the first:**

```
corp.internal:53 {
    errors
    cache 30
    forward . 10.50.0.53
}

.:53 {
    errors
    health { lameduck 5s }
    ready
    kubernetes cluster.local in-addr.arpa ip6.arpa {
       pods insecure
       fallthrough in-addr.arpa ip6.arpa
       ttl 30
    }
    prometheus :9153
    forward . /etc/resolv.conf { max_concurrent 1000 }
    cache 30
    loop
    reload
    loadbalance
}
```

**CoreDNS matches the most specific zone block**, so anything ending in
`corp.internal` is handled by the first block and everything else falls to `.`.
The existing block is untouched.

A `forward` stanza inside the main block is the alternative and is equivalent for
this case:

```
    forward corp.internal 10.50.0.53
```

The separate zone block is preferable because it gets its own `cache` and its
own error handling, and because it is obvious at a glance which names go where.

**2. Why not change `forward . /etc/resolv.conf`.**

Because `.` is **everything** — that line is the catch-all for the entire
internet. Repointing it at `10.50.0.53` sends `github.com`, container registry
lookups, and every external API call to the corporate resolver. If that resolver
does not do public recursion, **the cluster loses all external DNS**; if it does,
you have made an internal server a dependency of every outbound connection and
given yourself a single point of failure nobody documented.

**Change the zone you mean, not the default.**

**3. Applying it:**

```bash
kubectl -n kube-system edit configmap coredns
# ...or, safer, from a file you can diff and revert:
kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' > Corefile.bak
cp Corefile.bak Corefile.new && $EDITOR Corefile.new
kubectl -n kube-system create configmap coredns --from-file=Corefile=Corefile.new \
  --dry-run=client -o yaml | kubectl apply -f -
```

**Effective in about 30 seconds**, via the `reload` plugin (24.3). No restart,
no rollout, and no disruption to in-flight queries. Confirm:

```bash
kubectl -n kube-system logs -l k8s-app=kube-dns --tail=20 | grep -i reload
kubectl run t --rm -it --restart=Never \
  --image=registry.k8s.io/e2e-test-images/jessie-dnsutils:1.3 -- \
  dig +short something.corp.internal
```

**4. Rollback and how you would know.**

```bash
kubectl -n kube-system create configmap coredns --from-file=Corefile=Corefile.bak \
  --dry-run=client -o yaml | kubectl apply -f -
```

**How you would know:** the `reload` plugin is a double-edged tool — a Corefile
with a syntax error **fails to load and CoreDNS keeps serving the old one**,
logging the error. So the two things to watch are:

```bash
kubectl -n kube-system logs -l k8s-app=kube-dns --tail=30 | grep -iE "error|reload"
kubectl -n kube-system get pods -l k8s-app=kube-dns      # RESTARTS climbing = worse
```

`RESTARTS` climbing means the new configuration is bad enough to crash the
process, not merely be rejected — that is when you roll back immediately rather
than debugging in place. **Keep `Corefile.bak` before touching anything**, because
the rollback is only fast if the previous content is on disk.

### C4 - The `fallthrough` trap

**What happens to `kubernetes.default.svc.cluster.local`:**

1. The query reaches CoreDNS and enters the `.:53` server block.
2. The plugin chain runs **in CoreDNS's compiled order**, and `hosts` sits
   **before** `kubernetes` in that order.
3. The `hosts` plugin is authoritative for its zone. It looks up the name, finds
   nothing, and — with no `fallthrough` — **answers `NXDOMAIN` itself**.
4. The chain stops. **The `kubernetes` plugin is never called.**

**Every cluster name now returns NXDOMAIN.** Note *which* failure this is (24.6):
not a timeout, not a refusal — a confident, fast "that name does not exist" for
`kubernetes.default`, which is alarming precisely because it looks like DNS is
working perfectly.

**Why `hosts` is consulted for a name it has never heard of:** because a plugin's
position in the chain, not its data, decides whether it runs. `hosts` declares
itself authoritative for the zone it was given — and with no argument, that zone
is `.`, everything. Being authoritative means "I answer, including with
NXDOMAIN". `fallthrough` is the explicit opt-out: *if I have no record, pass the
query on instead of answering.*

The same trap applies to `file`, `template`, `kubernetes` itself, and any other
plugin that can answer authoritatively — which is why the stock Corefile has
`fallthrough in-addr.arpa ip6.arpa` on the `kubernetes` line.

**The fix:**

```
    hosts {
       10.9.9.9 internal.example
       fallthrough
    }
```

**The fastest recovery from a cluster already in this state:**

```bash
kubectl -n kube-system edit configmap coredns      # delete the block, or add fallthrough
```

and wait ~30 seconds for `reload`. **The critical point is that this still
works**: `kubectl` talks to the API server by IP or by a name resolved from your
workstation's resolver, **not through cluster DNS**. The control plane is
unaffected, so the tool you need to fix the problem is not itself broken.

If the reload does not take, force it:

```bash
kubectl -n kube-system rollout restart deployment coredns
```

**What is genuinely broken meanwhile** is every in-cluster client: applications
resolving Service names, webhooks called by name
([CKA 07](../../07-admission-controllers/)), and operators talking to
`kubernetes.default`. Expect a wave of errors that stops on its own once the
Corefile is corrected — and note that pods do **not** need restarting, because
nothing about them changed.

### C5 - Scale CoreDNS

**1. Four things to measure:**

| Measure | Command |
|---|---|
| **query rate and latency**, by type | `kubectl -n kube-system port-forward <coredns-pod> 9153` then `curl -s localhost:9153/metrics \| grep coredns_dns_request` |
| **CPU throttling** on the CoreDNS pods | `kubectl top pods -n kube-system -l k8s-app=kube-dns` and `container_cpu_cfs_throttled_seconds_total` |
| **NXDOMAIN rate** -- the `ndots` tax | `curl -s localhost:9153/metrics \| grep 'rcode="NXDOMAIN"'` |
| **conntrack table pressure** on the nodes | `docker exec <node> sh -c 'cat /proc/sys/net/netfilter/nf_conntrack_count /proc/sys/net/netfilter/nf_conntrack_max'` |

The third is the one people skip and it is usually the largest single number:
with `ndots:5`, **three quarters of all queries are NXDOMAIN by construction**
(24.5). If `coredns_dns_responses_total{rcode="NXDOMAIN"}` is roughly three times
`NOERROR`, the load is search-list overhead rather than real demand.

The fourth matters because **DNS over UDP creates a conntrack entry per query**,
and a node exhausting `nf_conntrack_max` drops packets silently — which presents
as intermittent DNS timeouts and nothing else. It is a classic and it is invisible
from the API.

**2. Three changes that reduce load:**

**(a) `ndots: 1` via `dnsConfig` on the noisiest workloads.**
Cuts external-name lookups from four queries to one.
**Trade-off:** short cluster names stop working in those pods, so the application
must use FQDNs. Per-workload, not cluster-wide.

**(b) NodeLocal DNSCache.**
A DaemonSet running a CoreDNS instance on every node, listening on a link-local
address; pods are pointed at it and it caches aggressively and forwards misses to
the central CoreDNS over **TCP**.
**Trade-off:** another component to run and upgrade, and cache staleness on
Service changes. It also fixes the conntrack problem, because pod-to-local-cache
traffic never leaves the node and the upstream hop is TCP rather than UDP. **This
is the standard answer for a cluster of this size.**

**(c) Raise `cache` in the Corefile, and set a longer `ttl` on the `kubernetes`
plugin.**
The default is 30 seconds for both.
**Trade-off:** slower propagation when endpoints change — a rolling update means
clients hold stale addresses for up to the TTL. Acceptable at 30s, questionable
at 300s, and it interacts badly with `Retain`-style long-lived connections.

**3. Why more replicas is often not the fix.**

Because **the bottleneck is usually not CoreDNS's capacity.** Three things
commonly present as "DNS is slow" and none of them improve with replicas:

- **conntrack exhaustion on the client's node.** The packet is dropped before it
  reaches any CoreDNS pod. Ten replicas do not help; the drop is local.
- **the `ndots:5` tax.** You are not short of DNS capacity, you are making four
  times more queries than necessary. More replicas serves the same waste faster.
- **a single slow upstream.** If `forward` points at a resolver that takes 2
  seconds for external names, every replica waits the same 2 seconds.

There is also a real cost: **each replica opens its own watch on Services and
EndpointSlices**, so at large scale more CoreDNS pods means more API server load,
and the API server is frequently the thing already under pressure.

**When it *is* the fix:** when the metrics show CoreDNS itself saturated — CPU
throttling on the pods, `coredns_dns_request_duration_seconds` climbing with
request rate, and queue depth growing — **and** the client-side and query-volume
causes have been ruled out. In that case scale up, and prefer
`cluster-proportional-autoscaler` so the replica count tracks node count instead
of being a number somebody set once.

**The order to work through: measure first, then `ndots`, then NodeLocalDNS, then
replicas.** Replicas are the change people try first because it is the easiest,
which is exactly why it is usually not the one that helps.

---

## Files

| File | Purpose |
|---|---|
| `01-workload.yaml` | a Service, a headless Service, a StatefulSet, and a **named** port |
| `02-dnsutils.yaml` | the debugging pod with a resolver that honours the search list |
| `03-dnspolicy-default.yaml` | `dnsPolicy: Default` -- the node's resolver, no cluster names |
| `04-hostnetwork-BAD.yaml` | `hostNetwork` with no `dnsPolicy` -- the silent trap |
| `05-hostnetwork-fixed.yaml` | the same pod plus `ClusterFirstWithHostNet` |
| `06-dnsconfig-ndots.yaml` | `ndots: 1`, and what it costs |
| `dns-map.sh` | the whole installation from the API side, in nine sections |
| `corefile-edit.sh` | `add` / `remove` / `restore` a hosts block, with a backup |
| `verify.sh` | checks every claim in Part 4 |

---

## On the choice of image

The lab uses `registry.k8s.io/e2e-test-images/jessie-dnsutils:1.3` rather than
busybox, and the reason is worth knowing independently of this assignment.

**BusyBox's `nslookup` does not apply the search list.** Ask it for `web` and it
queries `web` verbatim, gets NXDOMAIN, and reports failure — on a cluster where
`web` resolves perfectly from every real application. Different busybox versions
behave differently, which makes it worse: the same command works on
`busybox:1.28` and fails on `busybox:1.36`, or the reverse, depending on which
`nslookup` implementation was compiled in.

**This produces a false negative in the exact situation you are trying to
diagnose**, and it has sent a lot of people looking for a DNS fault that was
never there.

`jessie-dnsutils` is the image the Kubernetes documentation uses for DNS
debugging. It ships `dig`, `host` and a glibc `nslookup`, all of which honour
`resolv.conf` the way an application does.

**If you are stuck with busybox**, use FQDNs and nothing else — `dig` and
`nslookup` output from a busybox pod is only trustworthy for fully-qualified
names.

## On `corefile-edit.sh`

It exists because editing the Corefile is the single most common CoreDNS
operation and the one with the largest blast radius (C4). The script:

- **takes a backup on the first `add`**, to `/tmp/corefile.backup`, so `restore`
  is always available
- **inserts the block with `fallthrough` already present**, so the lab does not
  teach the broken form
- **applies via `create --dry-run=client -o yaml | kubectl apply -f -`**, the
  idiom for replacing a ConfigMap's contents from a file without deleting it
  first

Read what it does before running it. In an exam you would do the same edit with
`kubectl -n kube-system edit configmap coredns` — but you would still want to
have run `kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' >
backup` first.
