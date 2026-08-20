# CKA 16 solution

## Challenge answers

### C1 - Wire up a monitoring agent

```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: prometheus
  namespace: monitoring
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: prometheus-reader
rules:
  - apiGroups: [""]
    resources: ["pods", "nodes", "services"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: prometheus-reader
subjects:
  - kind: ServiceAccount
    name: prometheus
    namespace: monitoring        # REQUIRED -- the binding is cluster-scoped,
                                 # so the subject must say where the SA lives
roleRef:
  kind: ClusterRole
  name: prometheus-reader
  apiGroup: rbac.authorization.k8s.io
```

**1. Why a ClusterRoleBinding.** A RoleBinding grants permission **in one
namespace only**, even when it references a ClusterRole. "Read pods in every
namespace" cannot be expressed by a RoleBinding without creating one in every
namespace — including namespaces that do not exist yet. There is also a
non-negotiable reason: **`nodes` are cluster-scoped**, so no namespaced binding
can ever grant access to them.

**2. Why the ServiceAccount is still namespaced.** ServiceAccounts are namespaced
objects, full stop — there is no cluster-scoped variant. The identity
`system:serviceaccount:monitoring:prometheus` is usable from anywhere and means
the same thing everywhere; only the *object* has a home. That home matters
because it is where the pod must run to have the token mounted, and it is why
the `namespace:` field in the subject is mandatory rather than decorative.

**3. Prove it without deploying:**

```bash
kubectl auth can-i --list --as=system:serviceaccount:monitoring:prometheus
```

Or, more precisely for a single claim:

```bash
kubectl auth can-i list nodes --as=system:serviceaccount:monitoring:prometheus
kubectl auth can-i list pods  --as=system:serviceaccount:monitoring:prometheus -A
kubectl auth can-i delete pods --as=system:serviceaccount:monitoring:prometheus   # must be "no"
```

**Check the negative case too.** A ClusterRole with an accidental `"*"` in
`verbs` passes every positive test.

### C2 - The forbidden pod

```bash
# 1. does the pod use the SA you think it does?
kubectl get pod POD -n prod -o jsonpath='{.spec.serviceAccountName}{"\n"}'

# 2. does that identity have the permission, according to the API server itself?
kubectl auth can-i list pods --as=system:serviceaccount:prod:default -n prod

# 3. what bindings exist in this namespace, and who do they name?
kubectl get rolebinding,clusterrolebinding -n prod -o wide

# 4. what CAN that identity do?
kubectl auth can-i --list --as=system:serviceaccount:prod:default -n prod
```

| Cause | What you see |
|---|---|
| **Missing `serviceAccountName`** | (1) prints `default` — the message already told you this, and the fix is in the *pod spec*, not in RBAC |
| **Missing RoleBinding** | (3) shows no binding naming your SA at all; (4) lists only the universal `selfsubjectreviews` entries |
| **RoleBinding in the wrong namespace** | (3) run in `prod` shows nothing, but `kubectl get rolebinding -A \| grep <sa>` finds it elsewhere; (2) says `no` in `prod` and `yes` in that other namespace |
| **Typo in the subject** | (3) shows a binding that *looks* right; `-o yaml` reveals `kind: User` where it should be `kind: ServiceAccount`, or a missing `namespace:` field, or the wrong SA name |

**The fastest discriminator is (1) versus (2).** If (1) prints `default`, the
problem is the workload. If (1) prints the right SA and (2) says `no`, the
problem is RBAC — and (3) and (4) tell you which flavour.

The subject-typo case deserves care because it fails silently: **a RoleBinding
naming a non-existent subject is perfectly valid** and is created without a
warning. Kubernetes never checks that the subject exists.

### C3 - Blast radius

**1. What it grants.** `cluster-admin` — unrestricted control of every resource
in every namespace — to the group **`system:serviceaccounts`**, which contains
**every ServiceAccount in the cluster**, in every namespace, including
`default` in each one, including namespaces created afterwards (16.1).

Since every pod that names no ServiceAccount gets `default`, and `default`
belongs to that group, the practical effect is: **every pod in the cluster is now
cluster-admin.** Anything that can create a pod can do anything, and a
compromised container in any namespace owns the whole cluster.

**2. Why it is worse than `--user=someone`.** Three reasons, in increasing
order of severity:

- **It is not one identity, it is an unbounded set** that grows on its own. A new
  namespace is a new `default` ServiceAccount with cluster-admin, created by
  Kubernetes, with nobody deciding anything.
- **The credential is already distributed.** A user certificate has to be
  stolen; a ServiceAccount token is *mounted into every pod by default*
  (16.3). The attacker does not need a breach to get one — they need to be
  inside any container at all.
- **It is invisible where you would look.** Nothing about a pod, a Deployment or
  a namespace shows that it now has cluster-admin. The only trace is one
  ClusterRoleBinding whose subject is a group name that reads like a system
  default.

**3. Find it in an audit:**

```bash
kubectl get clusterrolebindings -o json | jq -r '
  .items[] | select(.roleRef.name=="cluster-admin") |
  "\(.metadata.name)  <-  \(.subjects // [] | map("\(.kind)/\(.name)") | join(", "))"'
```

Or without `jq`:

```bash
kubectl get clusterrolebinding -o custom-columns=\
NAME:.metadata.name,ROLE:.roleRef.name,SUBJECTS:.subjects[*].name | grep cluster-admin
```

The general form of the question — *who is cluster-admin?* — is one every
cluster owner should be able to answer in one command. The expected answer is
`system:masters` ([CKA 13](../../13-tls-in-kubernetes/)) and the kubeadm
bootstrap bindings, and **nothing else**. Anything extra needs an explanation.

The direct check, which is also the fastest:

```bash
kubectl auth can-i '*' '*' --all-namespaces --as=system:serviceaccount:default:default
```

If that prints `yes`, stop what you are doing.

**4. The smallest safe change.** Bind to the **one** ServiceAccount that
actually needed it, and to the **narrowest** role that solves the incident:

```bash
kubectl create clusterrolebinding fix \
  --clusterrole=cluster-admin \
  --serviceaccount=kube-system:the-controller-that-was-broken
```

Better still, if the incident merely needed reads:
`--clusterrole=view`. And best of all: **delete it once the incident is over.**
The real failure here is not the command, it is that a 3am mitigation became
permanent — which is why an audit query like (3) belongs in CI, not in a runbook
nobody opens.

### C4 - The token that stopped working

**The cause.** The mounted token is short-lived, roughly one hour (16.3). The
kubelet refreshes it in the background, **rewriting the file in place** at around
80% of its lifetime. The agent read the file once at startup and kept the string
in memory. When the original token's `exp` passed, the API server began rejecting
it — `401 Unauthorized`, meaning the credential itself was not accepted, not that
permissions were missing (that would be `403`).

Fifty minutes is the tell: it is neither a permissions problem (which would fail
on the first call) nor a network problem (which would not wait for a round
number).

**Why restarting "fixes" it.** The new process reads the file again, and gets
whatever the kubelet has most recently written — a fresh token good for another
hour. The bug is not fixed; the clock is reset. A restart-on-failure loop turns
this into a pod that mysteriously restarts every hour forever, which is how it
usually gets reported.

**The one-line fix:** read the file on **every** request, not once.

```python
headers = {"Authorization": "Bearer " + open(TOKEN_PATH).read()}   # inside the request function
```

Or, better, stop hand-rolling it — every official client library
(`client-go`, `kubernetes` for Python, and the rest) already re-reads the
projected token and this whole class of bug disappears.

**What 1.23 would have done.** The token came from an auto-created
`kubernetes.io/service-account-token` Secret and had **no `exp` claim at all**
(16.6). Reading it once at startup worked forever, so the bug was latent in a
great deal of code and nobody ever hit it.

**Why nobody noticed before 1.24.** Because the platform was hiding it. Tokens
that never expire mean "cache the credential forever" is a working strategy, so
it became the common one. Bounded tokens made a decade of accumulated shortcuts
visible in a single release — which is exactly why the change was worth making,
and why this failure mode showed up in so many operators at once.

### C5 - Choose the credential

| # | Case | Credential | Why |
|---|---|---|---|
| 1 | in-cluster operator | **pod-mounted SA token** | it runs in a pod; the token is bound to that pod, rotates itself, and dies with it |
| 2 | GitHub Actions running `kubectl` | **short-lived bearer token**, ideally via OIDC federation | the caller is outside the cluster and has no pod to bind to |
| 3 | human administrator | **client certificate** or OIDC | ServiceAccounts are for programs; a human needs an identity that can be revoked and audited as a person |
| 4 | twelve-year-old appliance | **legacy Secret token** | it cannot refresh, so a bounded token would break it hourly |
| 5 | `CronJob` deleting Jobs | **pod-mounted SA token** | a CronJob creates pods; each gets a fresh bound token automatically |

The two that need argument:

**Number 2.** `kubectl create token ci-deployer --duration=1h` works and is the
right answer on the exam. In production the better answer is **OIDC
federation** — GitHub Actions presents its own short-lived OIDC token, the API
server is configured to trust that issuer, and no Kubernetes credential is
stored in GitHub at all. The reason matters: a long-lived token pasted into a
CI secret store is a credential you cannot rotate, cannot audit per-run, and
will still be valid the day the repository is forked or the contractor leaves.
If you must use a static token, scope its ServiceAccount to exactly the
namespaces it deploys to and rotate it on a schedule you actually keep.

**Number 4** is the only legitimate use of 16.6, and it should come with
compensating controls, because you have deliberately created a permanent
credential:

- give it a ServiceAccount of its own, with the narrowest possible Role
- never let it near `cluster-admin` or any write verb it does not need
- put a calendar reminder to delete the Secret when the appliance is retired,
  because nothing else will ever tell you it is still there

**Number 3 is the one people get wrong.** Creating a ServiceAccount for a human
is tempting — it is one command and the token works immediately. It is wrong
because the resulting audit log says `system:serviceaccount:ops:alice-sa`
performed the action, which is an *account*, not a *person*: it cannot be tied
to an employee record, it survives their departure, and it can be handed to a
colleague with no trace. Humans get certificates
([CKA 13](../../13-tls-in-kubernetes/)) or, better, an identity provider.

---

## Files

| File | Purpose |
|---|---|
| `01-serviceaccounts.yaml` | `dashboard-sa`, `no-token-sa` (automount off), `legacy-sa` |
| `02-rbac.yaml` | Role + RoleBinding with a `kind: ServiceAccount` subject |
| `03-pod-default-sa.yaml` | names nothing -- gets `default` injected |
| `04-pod-dashboard-sa.yaml` | `serviceAccountName: dashboard-sa` |
| `05-pod-no-token.yaml` | no credential mounted at all |
| `06-pod-overrides-sa.yaml` | pod-level `true` beating the SA's `false` |
| `07-legacy-token-secret.yaml` | the pre-1.24 non-expiring token |
| `verify.sh` | checks every claim in Part 4 |

All of these are safe to apply together **after** you have watched steps 1-3 in
order, since the point of step 3 is seeing the `default` SA fail before
`dashboard-sa` exists.

---

## A note on the image

The pods use `curlimages/curl:8.10.1` because the lab makes real HTTPS calls to
the API server from inside a container, and most minimal images ship no HTTP
client that can send a custom header. `busybox`'s `wget` cannot reliably do
`--header` across versions, and `nginx:alpine` has no client at all.

If you would rather not pull another image, the same calls work from your
workstation using a token from `kubectl create token` (step 6) — you lose only
the demonstration that the credential is *already inside the pod*, which is the
part worth seeing once.
