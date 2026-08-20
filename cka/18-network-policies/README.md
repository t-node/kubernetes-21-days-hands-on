# CKA 18 — Network Policies

**Time:** 100-120 minutes
**Prerequisites:** [Day 06](../../days/day-06-services-clusterip-and-dns/), [Day 12](../../days/day-12-wire-the-three-tier-app/), [Day 18](../../days/day-18-scheduling-taints-affinity-daemonsets/)
**Source lectures:** 177, 178, 180

Kubernetes ships with **no network segmentation at all**. Every pod can reach
every other pod, in every namespace, on every port. This assignment is about
taking that away selectively — and about the two things that make it harder than
it looks: the AND/OR rule, and the fact that your cluster may be ignoring your
policies entirely.

---

## Part 1 - Concepts

### 18.1 The default is allow-everything

One of Kubernetes' networking requirements is that **every pod can reach every
other pod without NAT**. A flat network, no routes to configure, no firewall.

```
  web  ------>  api  ------>  db
   |             |             |
   +-------------+-------------+
   ...and web can also reach db directly, and db can reach the internet,
   and a pod in `dev` can reach a pod in `prod`.
```

That is convenient and it is also the entire problem: a compromised front-end can
open a TCP connection to your database. A `NetworkPolicy` is how you stop it.

### 18.2 Ingress and egress are about who *starts* the conversation

```
   user --(1)--> web --(2)--> api --(3)--> db
        <........     <........    <........
              replies are automatic
```

| From the pod's view | Direction |
|---|---|
| someone connects **to** me | **ingress** |
| I connect **out** to someone | **egress** |

**Only the direction the connection originates matters.** Network policies are
**stateful**: allow an ingress connection and the replies flow back without any
egress rule. This is the single most common conceptual error — writing an egress
rule "so the database can answer".

For `api -> db` on 3306, `db` needs **one ingress rule** and nothing else.

### 18.3 A policy makes its targets *isolated*

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: db-policy
  namespace: prod
spec:
  podSelector:
    matchLabels:
      role: db              # WHICH pods this policy protects
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              role: api
      ports:
        - protocol: TCP
          port: 3306
```

The mechanism is not "add a firewall rule". It is:

1. **`podSelector` picks the pods the policy applies to.** They become
   *isolated* for each direction named in `policyTypes`.
2. **An isolated pod denies everything in that direction by default.**
3. **The rules then add back exactly what is listed.**

So the policy above means: *`role: db` pods accept ingress only from `role: api`
pods on TCP 3306, and nothing else.* Egress is untouched — the policy says
nothing about it, so `db` can still connect anywhere.

Three consequences worth stating plainly:

- **`policyTypes` is what turns denial on.** A policy with
  `policyTypes: [Ingress]` and an empty `ingress:` list is a **deny-all-ingress**
  rule.
- **There are no deny rules.** You cannot write "deny from X". You isolate, then
  allow.
- **Policies are additive.** Two policies selecting the same pod produce the
  **union** of their allowances. There is no ordering, no priority, and no way
  for one policy to override another. If traffic matches *any* policy's allow
  rule, it passes.

**`podSelector: {}` means every pod in the namespace** — the basis of every
default-deny recipe:

```yaml
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
  # no rules at all == deny everything, both directions
```

### 18.4 Three selectors, and the AND/OR rule

Inside `from:` (or `to:`) you may use:

| Selector | Selects |
|---|---|
| `podSelector` | pods **in the policy's own namespace**, by label |
| `namespaceSelector` | **all pods** in namespaces matching a label |
| `ipBlock` | a CIDR range — for things outside the cluster |

**This is the detail that decides whether your policy works**, and it hinges on
YAML list syntax:

```yaml
# ONE list item containing TWO selectors  ==  AND
from:
  - namespaceSelector:
      matchLabels: {env: prod}
    podSelector:
      matchLabels: {role: api}
```
> *pods labelled `role: api` **that are also in** a namespace labelled
> `env: prod`.*

```yaml
# TWO list items, each with ONE selector  ==  OR
from:
  - namespaceSelector:
      matchLabels: {env: prod}
  - podSelector:
      matchLabels: {role: api}
```
> *any pod in a namespace labelled `env: prod`, **or** any `role: api` pod in
> this namespace.* Which is very nearly "everything".

**One dash is the whole difference.** Two policies that look almost identical
grant wildly different access, and nothing warns you. Part 2 makes you produce
both and watch them behave differently.

The rule generalises: **items in a list are OR'd; keys within one item are
AND'd.**

> **`podSelector` inside `from:` is namespace-local.** To allow a pod from
> another namespace you *must* pair it with a `namespaceSelector` — a bare
> `podSelector` will never match anything outside the policy's own namespace.

### 18.5 Egress, and the DNS trap

```yaml
spec:
  podSelector: {matchLabels: {role: web}}
  policyTypes: [Egress]
  egress:
    - to:
        - podSelector: {matchLabels: {role: api}}
      ports:
        - {protocol: TCP, port: 8080}
```

`to:` instead of `from:`; everything else is the same.

> **The trap that catches everybody:** the moment you isolate a pod for egress,
> **DNS stops working** — CoreDNS is just another pod, and you did not allow
> traffic to it. Your application then fails with "no such host", which looks
> nothing like a network policy problem.

Every egress policy needs this block:

```yaml
  egress:
    - to:
        - namespaceSelector:
            matchLabels: {kubernetes.io/metadata.name: kube-system}
          podSelector:
            matchLabels: {k8s-app: kube-dns}
      ports:
        - {protocol: UDP, port: 53}
        - {protocol: TCP, port: 53}
```

Note it needs **UDP and TCP** — large responses fall back to TCP — and note the
`kubernetes.io/metadata.name` label, which Kubernetes sets automatically on
every namespace so you can select one by name without labelling it yourself.

### 18.6 What network policies do not do

| | |
|---|---|
| **They are not enforced by Kubernetes.** | The **CNI plugin** enforces them. Calico, Cilium and kube-router do; **kindnet and Flannel do not.** |
| **An unsupported cluster gives no error.** | The object is created, `kubectl get netpol` lists it, and nothing happens. **This is the most dangerous failure mode in the whole topic** and you will reproduce it in Part 2A. |
| **They do not apply to `hostNetwork` pods.** | Those use the node's network namespace. |
| **They select pods, not Services.** | Traffic is evaluated on **pod IPs after DNAT**, so a rule allowing a Service's ClusterIP is meaningless — select the backing pods. |
| **`ipBlock` sees the source IP as it arrives.** | If something SNATs on the way in — a node port, a cloud load balancer — you see the node's IP, not the client's. |

---

## Part 2 - Hands-on lab

### A. Watch a policy do nothing

**Do this first, on your normal `devops` cluster.** It is the most useful five
minutes in this assignment.

```bash
kubectl config use-context kind-devops
kubectl create namespace cka18
kubectl apply -f solution/00-three-tier.yaml
kubectl wait --for=condition=Ready pod --all -n cka18 --timeout=120s
```

Confirm the flat network from 18.1 — everything reaches everything:

```bash
kubectl exec -n cka18 web -- curl -s -o /dev/null -w "web->db  %{http_code}\n" --max-time 5 http://db
kubectl exec -n cka18 api -- curl -s -o /dev/null -w "api->db  %{http_code}\n" --max-time 5 http://db
```

```
web->db  200
api->db  200
```

Now lock it down completely:

```bash
kubectl apply -f solution/01-default-deny-ingress.yaml
kubectl get netpol -n cka18
sleep 5
kubectl exec -n cka18 web -- curl -s -o /dev/null -w "web->db  %{http_code}\n" --max-time 5 http://db
```

```
web->db  200
```

**Still 200.** The policy exists, `kubectl get netpol` lists it, `describe` shows
a correct deny-all rule — and nothing changed.

```bash
kubectl describe netpol default-deny-ingress -n cka18
kubectl get pods -n kube-system | grep -E "kindnet|calico|cilium"
```

```
kindnet-xxxxx    1/1  Running
```

**kindnet does not implement NetworkPolicy** (18.6). No error, no warning, no
event — the object is stored by the API server and no controller ever acts on
it.

> **This is the failure mode to fear.** A security review sees the policies. An
> audit sees the policies. `kubectl get netpol` sees the policies. The traffic
> does not. **Always verify a policy by testing traffic, never by reading YAML.**

```bash
kubectl delete namespace cka18
```

### B. A cluster that enforces them

```bash
kind create cluster --name netpol-lab --config solution/kind-calico.yaml
kubectl config use-context kind-netpol-lab
kubectl get nodes
```

```
NAME                       STATUS     ROLES           AGE   VERSION
netpol-lab-control-plane   NotReady   control-plane   30s   v1.31.4
netpol-lab-worker          NotReady   <none>          15s   v1.31.4
```

**`NotReady`, deliberately.** `disableDefaultCNI: true` means there is no network
plugin at all — nodes cannot be Ready and no pod can get an IP.

```bash
bash solution/install-calico.sh
kubectl get nodes
kubectl get pods -n kube-system | grep calico
```

Everything from here runs on **`kind-netpol-lab`**.

```bash
kubectl create namespace cka18
kubectl config set-context --current --namespace=cka18
kubectl apply -f solution/00-three-tier.yaml
kubectl wait --for=condition=Ready pod --all -n cka18 --timeout=180s
```

Save the test as a function — you will run it a dozen times:

```bash
probe() { kubectl exec -n "${3:-cka18}" "$1" -- curl -s -o /dev/null \
  -w "$1 -> $2  %{http_code}\n" --max-time 5 "http://$2" 2>&1 | tail -1; }

probe web db
probe api db
```

```
web -> db  200
api -> db  200
```

Same flat network as before. Now the same policy, on a cluster that means it:

```bash
kubectl apply -f solution/01-default-deny-ingress.yaml
sleep 5
probe web db
probe api db
```

```
web -> db  000
api -> db  000
```

**`000` is curl reporting no response at all** — the connection was dropped, not
refused. Everything is isolated for ingress, including `api -> db`, which you do
want.

### C. Add back exactly one path

```bash
kubectl apply -f solution/02-db-allow-api.yaml
sleep 5
probe api db      # 200
probe web db      # 000
probe web api     # 000 -- api-server is still covered by default-deny
```

**`api -> db` works; `web -> db` does not.** Two policies now select the `db`
pod, and the result is the **union** of their allowances (18.3) — deny-all plus
one allow equals one allow.

Note what you did *not* have to write: any egress rule on `api`, and any rule
letting the reply back to `api`. Policies are stateful (18.2).

```bash
kubectl describe netpol db-allow-api
```

Read the bottom of that output:

```
  Not affecting egress traffic
  Policy Types: Ingress
```

**`describe netpol` tells you what a policy leaves alone**, which is usually the
faster way to spot a missing `policyTypes` entry.

### D. AND versus OR — one dash

This is the centrepiece. Create the second namespace:

```bash
kubectl apply -f solution/09-prod-namespace.yaml
kubectl wait --for=condition=Ready pod --all -n cka18-prod --timeout=120s
kubectl get ns cka18-prod --show-labels
```

Two pods there: `prod-api` (labelled `role: api`) and `prod-decoy` (labelled
`role: definitely-not-api`). **Neither should be able to reach the database.**

```bash
kubectl delete netpol db-allow-api -n cka18
kubectl apply -f solution/03-and-rule.yaml
sleep 5

probe prod-api   db.cka18.svc.cluster.local cka18-prod
probe prod-decoy db.cka18.svc.cluster.local cka18-prod
probe api        db
```

```
prod-api   -> db  200      <- role=api AND in env=prod: allowed
prod-decoy -> db  000      <- wrong label: denied
api        -> db  000      <- right label, wrong namespace: denied
```

**Now change one character.** Diff the two files first:

```bash
diff solution/03-and-rule.yaml solution/04-or-rule.yaml
```

```
<           podSelector:                # <- NO dash: same list item as above
---
>         - podSelector:                # <- DASH: a second, independent rule
```

```bash
kubectl delete netpol db-allow-and -n cka18
kubectl apply -f solution/04-or-rule.yaml
sleep 5

probe prod-api   db.cka18.svc.cluster.local cka18-prod
probe prod-decoy db.cka18.svc.cluster.local cka18-prod
probe api        db
```

```
prod-api   -> db  200
prod-decoy -> db  200      <- !!! it should never have had access
api        -> db  200
```

**`prod-decoy` is now talking to your database.** One dash turned "api pods in
prod" into "everything in prod, or anything labelled api here" — and the policy
still reads like a restriction (18.4).

```bash
kubectl delete netpol db-allow-or -n cka18
kubectl apply -f solution/05-cross-namespace.yaml
sleep 5
probe prod-api   db.cka18.svc.cluster.local cka18-prod   # 200
probe prod-decoy db.cka18.svc.cluster.local cka18-prod   # 000
```

### E. The DNS trap

```bash
probe web api          # 000 -- still covered by default-deny-ingress
kubectl delete netpol default-deny-ingress -n cka18
sleep 3
probe web api          # 200
```

Now restrict what `web` may call **out** to:

```bash
kubectl apply -f solution/06-egress-no-dns-BAD.yaml
sleep 5
kubectl exec -n cka18 web -- curl -s --max-time 5 http://api 2>&1 | tail -2
```

```
curl: (6) Could not resolve host: api
```

**Not a connection failure — a name resolution failure.** The policy explicitly
allows `web -> api` on TCP 80, and the message says nothing about policies. This
is exactly how it presents in production, and it is why people spend an hour
looking at CoreDNS.

Prove the rule itself is fine by bypassing DNS:

```bash
API_IP=$(kubectl get pod api-server -n cka18 -o jsonpath='{.status.podIP}')
kubectl exec -n cka18 web -- curl -s -o /dev/null -w "by IP: %{http_code}\n" --max-time 5 "http://$API_IP"
```

```
by IP: 200
```

**Works by IP, fails by name.** That two-command comparison is the diagnosis:
the traffic rule is correct and DNS is blocked.

```bash
kubectl exec -n cka18 web -- nslookup api 2>&1 | tail -3
```

Fix it:

```bash
kubectl delete netpol web-egress-broken -n cka18
kubectl apply -f solution/07-egress-with-dns.yaml
sleep 5
kubectl exec -n cka18 web -- curl -s -o /dev/null -w "by name: %{http_code}\n" --max-time 5 http://api
probe web db
```

```
by name: 200
web -> db  000
```

**By name again, and `web -> db` is still blocked** — because `07` allows egress
only to `role: api` and to DNS. Read it once more and note there are **two list
items** under `egress:`, which is the OR from 18.4 used correctly: DNS *or*
the api tier.

Check the CoreDNS labels for yourself rather than trusting the manifest:

```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns --show-labels
```

> If your cluster's DNS pods carry a different label, the rule silently matches
> nothing and you are back where you started. **Always verify the selector
> against the real pods.**

### F. ipBlock

```bash
kubectl delete netpol --all -n cka18
kubectl apply -f solution/01-default-deny-ingress.yaml
kubectl apply -f solution/08-ipblock.yaml
sleep 5

probe api db                    # 000 -- pods are not in 172.18.0.0/16
kubectl get pod api -n cka18 -o jsonpath='{.status.podIP}{"\n"}'
kubectl get nodes -o wide | awk '{print $1, $6}'
```

**Pods live in `192.168.0.0/16` and nodes in `172.18.0.0/16`** — the CIDR you
allowed is the Docker network the kind nodes sit on, not the pod network. So the
`ipBlock` rule allows the *nodes* and no pods at all.

That is the point worth taking away: **`ipBlock` is for things outside the
cluster.** Selecting pods with a CIDR works until the pod network is renumbered,
a pod moves, or the address is reused — use `podSelector` for pods, always.

```bash
kubectl exec -n cka18 db -- hostname -i
```

### G. Write one yourself

Before reading the solution: **allow `web -> api` on TCP 80 only, deny
everything else in the namespace, and keep DNS working for every pod.**

You need three policies. Sketch them, apply them, and test with `probe` in every
direction — including the ones that should fail.

### Cleanup

```bash
kubectl delete namespace cka18 cka18-prod --ignore-not-found
kubectl config use-context kind-devops
kind delete cluster --name netpol-lab      # only when you are finished
```

Keep `netpol-lab` until `verify.sh` has run.

---

## Part 3 - Challenges

### C1 - The three-tier lockdown

Write the complete policy set for:

- `web` accepts ingress **only** from the ingress controller
  (namespace `ingress-nginx`) on 8080
- `api` accepts ingress **only** from `web` on 8080
- `db` accepts ingress **only** from `api` on 5432
- every pod may resolve DNS
- `api` may additionally reach `payments.external.example` on 443, which
  resolves to `203.0.113.0/24`
- nothing else, in either direction

State how many NetworkPolicy objects you used and why you did not use one.

### C2 - Debug a policy that denies too much

An application worked, a policy was applied, and now `api` returns 500s. `api`
can still reach `db`. Give the ordered command sequence to determine whether the
problem is ingress on `api`, egress from `api`, DNS, or something that is not a
network policy at all. For each outcome, name the observation that proves it.

### C3 - The dash

Given this fragment protecting `role: db` in namespace `prod`:

```yaml
  ingress:
    - from:
        - podSelector:
            matchLabels: {role: api}
        - namespaceSelector:
            matchLabels: {env: staging}
```

1. List every pod in the cluster that can now reach the database.
2. State what the author almost certainly intended.
3. Write the corrected fragment.
4. Give the `kubectl` command that would have revealed the mistake without
   reading the YAML.

### C4 - Two policies, one pod

```yaml
# policy-a
spec:
  podSelector: {matchLabels: {role: db}}
  policyTypes: [Ingress]
  ingress:
    - from: [{podSelector: {matchLabels: {role: api}}}]
```
```yaml
# policy-b
spec:
  podSelector: {matchLabels: {role: db}}
  policyTypes: [Ingress]
  ingress:
    - from: [{podSelector: {matchLabels: {role: web}}}]
```

Both exist. Can `web` reach `db`? Can a pod with **no** labels? Now delete
`policy-b` — what changes? Explain the model that makes all three answers
obvious, and say what you would have to do to express "`web` must **never**
reach `db`, whatever anyone else writes".

### C5 - The policy that does nothing

You inherit a cluster. `kubectl get netpol -A` returns 40 policies. Give the
procedure — commands and reasoning — that determines whether any of them are
being enforced, without disrupting production traffic. Then say what you would
do if the answer is no, given that you cannot change the CNI this quarter.

---

## Part 4 - Verify

```bash
bash solution/verify.sh
```

Run it on **`kind-netpol-lab`**. It checks that Calico is running, that the
default-deny policy actually drops traffic, that `api -> db` is allowed while
`web -> db` is not, that the AND rule admits `prod-api` and rejects
`prod-decoy`, and that an egress policy without a DNS rule breaks name
resolution while leaving IP connectivity intact.

---

## Part 5 - Exam notes

**Fast paths**

```bash
# there is NO kubectl create networkpolicy -- always write YAML
kubectl get netpol -A
kubectl describe netpol NAME        # read "Not affecting ... traffic" at the bottom

# which pods does a policy actually select?
kubectl get pods -l role=db --show-labels

# test traffic -- the ONLY way to verify a policy
kubectl run probe --rm -it --image=curlimages/curl:8.10.1 --restart=Never -- \
  curl -s -o /dev/null -w "%{http_code}\n" --max-time 5 http://db

# is anything even enforcing policy?
kubectl get pods -n kube-system | grep -E "calico|cilium|kube-router|kindnet|flannel"

# a namespace can always be selected by name, no labelling required
namespaceSelector:
  matchLabels: {kubernetes.io/metadata.name: kube-system}
```

The two recipes worth memorising:

```yaml
# deny everything, both directions, in this namespace
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
```

```yaml
# allow DNS -- attach to EVERY egress policy
egress:
  - to:
      - namespaceSelector:
          matchLabels: {kubernetes.io/metadata.name: kube-system}
        podSelector:
          matchLabels: {k8s-app: kube-dns}
    ports:
      - {protocol: UDP, port: 53}
      - {protocol: TCP, port: 53}
```

**Traps**

- **Your CNI may ignore policies entirely**, silently. kindnet and Flannel do.
  **Verify with traffic, never with `kubectl get`.**
- **One list item with two selectors is AND; two list items is OR.** One dash.
- **`podSelector` in `from:` is namespace-local.** Cross-namespace needs a
  `namespaceSelector` in the *same* list item.
- **Policies are stateful.** Never write an egress rule "for the reply".
- **Isolating for egress breaks DNS.** Always add the kube-dns rule, UDP *and*
  TCP.
- **`policyTypes` is what enables denial.** Omitting `Egress` leaves egress
  wide open however many `egress:` rules you wrote.
- **Policies are additive and there is no deny.** You cannot override an allow
  written by someone else.
- **`podSelector: {}` is every pod; an empty `from: []` is nothing.** `{}` and
  `[]` mean opposite things here.
- **Select pods, not Services.** Rules are evaluated on pod IPs after DNAT.
- **`hostNetwork` pods are not covered.**
- **`ports` narrows a rule.** Omit it and *every* port is allowed from that
  source.
- Short name: **`netpol`**.

---

**Previous:** [CKA 17 — Image Security and Security Contexts](../17-image-security-and-security-contexts/)
**Next: CKA 19 — CRDs, Custom Controllers and Operators** *(not yet built — see [CURRICULUM.md](../CURRICULUM.md))*
