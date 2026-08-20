# CKA 18 solution

## Challenge answers

### C1 - The three-tier lockdown

**Four objects**, and the reason it is not one is at the end.

```yaml
---
# 1. deny everything in both directions, for every pod in the namespace
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: default-deny, namespace: prod}
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
---
# 2. DNS for everyone -- without this, nothing resolves anything
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: allow-dns, namespace: prod}
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector:
            matchLabels: {kubernetes.io/metadata.name: kube-system}
          podSelector:
            matchLabels: {k8s-app: kube-dns}
      ports:
        - {protocol: UDP, port: 53}
        - {protocol: TCP, port: 53}
---
# 3. the application paths -- one policy per tier it protects
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: web-policy, namespace: prod}
spec:
  podSelector: {matchLabels: {role: web}}
  policyTypes: [Ingress, Egress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels: {kubernetes.io/metadata.name: ingress-nginx}
      ports: [{protocol: TCP, port: 8080}]
  egress:
    - to:
        - podSelector: {matchLabels: {role: api}}
      ports: [{protocol: TCP, port: 8080}]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: api-policy, namespace: prod}
spec:
  podSelector: {matchLabels: {role: api}}
  policyTypes: [Ingress, Egress]
  ingress:
    - from:
        - podSelector: {matchLabels: {role: web}}
      ports: [{protocol: TCP, port: 8080}]
  egress:
    - to:
        - podSelector: {matchLabels: {role: db}}
      ports: [{protocol: TCP, port: 5432}]
    - to:
        - ipBlock: {cidr: 203.0.113.0/24}
      ports: [{protocol: TCP, port: 443}]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: db-policy, namespace: prod}
spec:
  podSelector: {matchLabels: {role: db}}
  policyTypes: [Ingress, Egress]
  ingress:
    - from:
        - podSelector: {matchLabels: {role: api}}
      ports: [{protocol: TCP, port: 5432}]
```

Five, if you count `db-policy` separately — and **that is the answer to "why not
one"**: a NetworkPolicy has exactly **one `podSelector`**. Every rule inside it
applies to the same set of pods. Three tiers with three different rule sets is
therefore three policies, minimum, whatever you would prefer.

Details worth defending:

- **`allow-dns` selects `podSelector: {}`** so it covers every pod including ones
  added later. Because policies are additive (18.3), this union with each tier's
  own egress rule rather than conflicting with it.
- **`db-policy` declares `Egress` with no egress rules.** That is deliberate: the
  database originates no outbound connections, so isolating it for egress and
  allowing nothing is exactly right. It still answers `api`, because replies are
  stateful. (If it needed DNS it would already have it from `allow-dns`.)
- **The external payment API is an `ipBlock`** — it is outside the cluster, so
  `podSelector` cannot name it (18.4). Note the fragility: if that CIDR changes,
  this breaks, and DNS resolution of `payments.external.example` still works
  because `allow-dns` is separate.
- **The ingress controller is matched by namespace, not pod label**, because you
  do not control its labels and they change between chart versions.
  `kubernetes.io/metadata.name` is set by Kubernetes and cannot drift.

### C2 - Debug a policy that denies too much

```bash
# 1. What selects this pod at all? If nothing, it is not a policy problem.
kubectl get netpol -n prod -o json | jq -r '.items[] |
  "\(.metadata.name)  selects: \(.spec.podSelector)  types: \(.spec.policyTypes)"'
kubectl get pod api-xxx -n prod --show-labels

# 2. Ingress or egress? Ask from both sides.
kubectl exec -n prod web-xxx -- curl -s -o /dev/null -w "%{http_code}\n" --max-time 5 http://api:8080
kubectl exec -n prod api-xxx -- curl -s -o /dev/null -w "%{http_code}\n" --max-time 5 http://db:5432

# 3. Is it DNS, or the connection?
kubectl exec -n prod api-xxx -- nslookup db
DB_IP=$(kubectl get pod db-xxx -n prod -o jsonpath='{.status.podIP}')
kubectl exec -n prod api-xxx -- curl -s -o /dev/null -w "%{http_code}\n" --max-time 5 "http://$DB_IP:5432"

# 4. Not a policy at all?
kubectl logs -n prod api-xxx --tail=50
kubectl get endpoints -n prod
```

| Observation | Conclusion |
|---|---|
| step 2, `web -> api` is `000` **and** `api -> db` works | **ingress on `api`** — the api's own ingress rule does not admit `web` |
| step 2, `web -> api` works and `api -> db` is `000` | **egress from `api`** (or ingress on `db` — step 3 separates them) |
| step 3, `nslookup` fails but the **IP** connects | **DNS** — an egress policy is isolating the pod without a kube-dns rule (18.5) |
| step 3, both the name **and** the IP connect, yet the app 500s | **not a network policy.** The path works; look at logs, `endpoints`, and the application's own configuration |

**The `api` case in the question already tells you something**: `api -> db` still
works, so any policy affecting `api` is not blocking its egress to the database.
That points at **ingress on `api`** or at something outside networking — and step
3's IP-versus-name comparison is what settles it.

**The observation that proves "not a policy" is connectivity by IP.** If packets
reach the destination port, no NetworkPolicy is dropping them, and every minute
spent reading policy YAML after that is wasted.

### C3 - The dash

```yaml
  ingress:
    - from:
        - podSelector:
            matchLabels: {role: api}
        - namespaceSelector:
            matchLabels: {env: staging}
```

**1. Who can reach the database:**

- every pod labelled `role: api` **in the `prod` namespace** (a bare
  `podSelector` is namespace-local, 18.4)
- **every pod, of every kind, in every namespace labelled `env: staging`** —
  the whole staging estate

Two independent list items, so OR. And on **every port**, because the rule has
no `ports:` field.

**2. The intent** was almost certainly *"api pods from staging"* — one source,
two conditions. What was written grants the entire staging namespace access to
the production database, which is close to the opposite of a security control.

**3. Corrected:**

```yaml
  ingress:
    - from:
        - namespaceSelector:
            matchLabels: {env: staging}
          podSelector:                       # same list item -> AND
            matchLabels: {role: api}
      ports:
        - {protocol: TCP, port: 5432}
```

Two fixes, not one: the dash **and** the missing `ports:`. A rule without
`ports:` allows every port from an allowed source, which is rarely what anyone
means.

**4. The command that reveals it without reading YAML** — test the traffic:

```bash
kubectl run canary -n staging --rm -it --restart=Never \
  --image=curlimages/curl:8.10.1 --labels="role=definitely-not-api" -- \
  curl -s -o /dev/null -w "%{http_code}\n" --max-time 5 http://db.prod:5432
```

A pod with a label nobody would allow, in the namespace in question. **If it
connects, the policy is wider than intended.** This is the general technique and
it beats review: policy YAML reads as restrictive whether or not it is, so you
test with the traffic you expect to be denied.

`kubectl describe netpol` is the weaker second-best — it renders the rules as
prose and makes the OR visible as two separate `From:` blocks — but only traffic
proves it.

### C4 - Two policies, one pod

**Can `web` reach `db`? Yes.** `policy-b` allows it, and that is sufficient.

**Can an unlabelled pod? No.** Neither policy names it, and both policies select
`db` for `Ingress`, so `db` is isolated and only the listed sources get in.

**Delete `policy-b`: `web` can no longer reach `db`.** `policy-a` still isolates
`db` and no longer has anything allowing `web`.

**The model that makes all three obvious:**

1. **Isolation is a property of the pod, not of a policy.** As soon as *any*
   policy selects `db` for `Ingress`, `db` denies all ingress by default. Two
   policies isolate it no more than one does.
2. **Allow rules are a union.** Traffic is permitted if **any** policy selecting
   that pod permits it. There is no evaluation order, no priority, no
   first-match, and no deny.

So the answer to any "can X reach Y" question is: *is Y isolated for that
direction, and does at least one rule allow X?*

**"`web` must never reach `db`, whatever anyone else writes" — you cannot express
that with NetworkPolicy.** The API has no deny primitive, and anyone who can
create a NetworkPolicy in that namespace can add an allow that you cannot
override. Three real options:

- **RBAC.** Remove `create` on `networkpolicies` from everyone who should not be
  widening access. The policy set is only as strong as who may edit it.
- **A CRD from your CNI.** Calico's `GlobalNetworkPolicy` and Cilium's
  `CiliumClusterwideNetworkPolicy` both support **explicit deny rules with
  ordering**, evaluated before namespaced Kubernetes policies. This is the
  actual answer in production, and it is why large clusters end up using the
  CNI's own API rather than the portable one.
- **Separate the workloads** so the question does not arise — different
  clusters, or nodes the other workload cannot be scheduled onto.

**`AdminNetworkPolicy`** (a newer, cluster-scoped API with `Deny` and priority)
is the standardised version of the second option. It is worth naming in an
interview; it is not on the exam.

### C5 - The policy that does nothing

**The procedure, non-disruptive throughout:**

**1. Identify the CNI.** This alone usually answers the question:

```bash
kubectl get pods -n kube-system -o wide | grep -E "calico|cilium|kube-router|flannel|kindnet|weave|antrea"
kubectl get daemonset -n kube-system
ls /etc/cni/net.d/                       # on a node
```

Calico, Cilium, kube-router, Weave and Antrea enforce policy. **Flannel and
kindnet do not.** If you see only Flannel, you have your answer and the other
steps are confirmation.

**2. Confirm empirically, in a namespace you create.** Never test in production:

```bash
kubectl create namespace netpol-canary
kubectl -n netpol-canary run server --image=nginx:alpine
kubectl -n netpol-canary expose pod server --port=80
kubectl -n netpol-canary run client --image=curlimages/curl:8.10.1 -- sleep 3600

kubectl -n netpol-canary exec client -- curl -s -o /dev/null -w "%{http_code}\n" --max-time 5 http://server
# expect 200

kubectl -n netpol-canary apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: deny-all}
spec:
  podSelector: {}
  policyTypes: [Ingress]
EOF
sleep 5
kubectl -n netpol-canary exec client -- curl -s -o /dev/null -w "%{http_code}\n" --max-time 5 http://server
# 000 = enforced. 200 = the 40 policies are decoration.

kubectl delete namespace netpol-canary
```

**This is the whole answer**, and it touches nothing anyone depends on. Two
pods, one policy, one namespace, thirty seconds.

**3. If enforcement works, check the policies are doing what they claim.** Ten
correct policies and thirty that select nothing is the common state:

```bash
# policies whose podSelector matches no pods -- pure decoration
for ns in $(kubectl get ns -o name | cut -d/ -f2); do
  for p in $(kubectl get netpol -n "$ns" -o name 2>/dev/null); do
    sel=$(kubectl get "$p" -n "$ns" -o jsonpath='{.spec.podSelector.matchLabels}')
    echo "$ns/$p selects $sel"
  done
done
```

Then spot-check the important ones with the canary technique from C3.

**If the answer is no, and you cannot change the CNI this quarter:**

**Say so, in writing, to whoever believes the cluster is segmented.** That is the
first action, not the last. The gap between "40 policies exist" and "no traffic
is restricted" is exactly the kind of thing that appears in an incident review,
and the value of finding it is lost if nobody is told.

Then, in order of what you can actually do:

1. **Keep the policies.** They are correct declarations, they cost nothing, and
   they start working the day the CNI changes. Deleting them destroys the work.
2. **Add a CI check** that flags any *new* policy as non-enforcing, so nobody
   else is misled.
3. **Compensate elsewhere.** Segmentation you can still get without a CNI
   change: separate namespaces with RBAC, separate node pools with taints
   ([Day 18](../../../days/day-18-scheduling-taints-affinity-daemonsets/)),
   authentication between services rather than network reachability
   (mTLS, or application-level tokens), and moving the genuinely sensitive
   workload — usually the database — **out of the cluster** or into its own.
4. **Price the CNI migration** and put it on the roadmap with the finding from
   step 1 attached. A Calico or Cilium migration is a real project — it is a
   cluster-wide network change, usually done by building a new cluster and
   moving workloads — which is why "this quarter" was never realistic and why
   the compensating controls matter more than the migration date.

**What not to do:** do not quietly install a policy-enforcing CNI alongside the
existing one to "just make it work". Two CNIs on one cluster is a networking
outage waiting for a maintenance window.

---

## Files

| File | Purpose |
|---|---|
| `kind-calico.yaml` | a kind cluster with `disableDefaultCNI` and Calico's pod subnet |
| `install-calico.sh` | pinned Calico install, with the NotReady-before state shown |
| `00-three-tier.yaml` | web / api / db, plus servers and Services to probe |
| `01-default-deny-ingress.yaml` | `podSelector: {}` + `policyTypes: [Ingress]` |
| `02-db-allow-api.yaml` | one path added back |
| `03-and-rule.yaml` | two selectors, **one** list item |
| `04-or-rule.yaml` | the same two selectors, **two** list items |
| `05-cross-namespace.yaml` | the correct cross-namespace form |
| `06-egress-no-dns-BAD.yaml` | the DNS trap |
| `07-egress-with-dns.yaml` | the same policy, fixed |
| `08-ipblock.yaml` | CIDR-based rules, and their limits |
| `09-prod-namespace.yaml` | a labelled namespace with an api pod and a decoy |
| `verify.sh` | applies and removes policies while testing real traffic |

`03` and `04` are the two files to keep. Run `diff` on them before an exam.

---

## Why this assignment needs a second cluster

The repo's `devops` cluster runs **kindnet**, which implements pod networking and
**not** NetworkPolicy. Every policy in this directory would apply cleanly there,
appear in `kubectl get netpol`, and change nothing.

That is not a limitation to work around — **Part 2A makes you see it happen**,
because it is the most consequential thing in the topic and it is invisible by
construction. Only after that does the lab move to a Calico cluster where the
same YAML actually does something.

`kind-calico.yaml` sets two things:

- **`disableDefaultCNI: true`** — no kindnet, so nodes stay `NotReady` until
  Calico is installed. Worth seeing once: it is what a cluster with no network
  plugin looks like.
- **`podSubnet: 192.168.0.0/16`** — Calico's default IP pool. Matching them
  avoids having to configure an `IPPool` by hand, which is the usual reason a
  kind-plus-Calico cluster comes up half-working.

The cluster costs about two minutes to create and a `kind delete` to remove. Keep
it while working through CKA 18 and delete it afterwards; nothing else in the
repo depends on it.
