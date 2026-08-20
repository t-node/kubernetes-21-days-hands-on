# CKA 16 — Service Accounts and Tokens

**Time:** 75-90 minutes
**Prerequisites:** [Day 19](../../days/day-19-rbac/), [CKA 13](../13-tls-in-kubernetes/), [CKA 15](../15-certificates-api-and-authorization/)
**Source lectures:** 167, 169

[CKA 13](../13-tls-in-kubernetes/) covered how a *human* authenticates: a client
certificate whose `CN` is the username. This assignment covers how a *program*
does it — and the answer is deliberately different, because a pod cannot be
handed a private key at install time.

---

## Part 1 - Concepts

### 16.1 Two kinds of account, one of which is not an object

| | **User account** | **Service account** |
|---|---|---|
| For | humans | programs |
| Kubernetes object | **none** | **`ServiceAccount`** |
| Scope | cluster-wide string | **namespaced** |
| Credential | client certificate, OIDC token | **a JWT** |
| Created by | your CA, or an identity provider | `kubectl create serviceaccount` |

**There is no `User` object in Kubernetes.** `kubectl get users` does not exist.
A "user" is just a string the API server extracted from a certificate
([CKA 13](../13-tls-in-kubernetes/)) or a token, and RBAC binds to that string.

A ServiceAccount, by contrast, is a real, namespaced object you can create, list
and delete. That asymmetry surprises people, and it is a stock exam question.

**The username of a ServiceAccount** is mechanical:

```
system:serviceaccount:<namespace>:<name>
```

That is the string that appears in error messages, in audit logs, and in
`--as`. It also belongs to two groups automatically:

| Group | Contains |
|---|---|
| `system:serviceaccounts` | **every** ServiceAccount in the cluster |
| `system:serviceaccounts:<namespace>` | every ServiceAccount in that namespace |

Granting anything to those groups grants it to every workload in scope. It is
occasionally the right tool and usually a mistake.

### 16.2 Every namespace has a `default`

Create a namespace and Kubernetes creates a `default` ServiceAccount in it. Every
pod that does not name one gets it — injected by the **`ServiceAccount` admission
controller** ([CKA 07](../07-admission-controllers/)), which also arranges the
token mount.

```yaml
spec:
  serviceAccountName: dashboard-sa      # name it, or get `default`
```

**The `default` ServiceAccount has no permissions at all.** That is deliberate:
a pod that does nothing with the API needs nothing, and a pod that does needs a
ServiceAccount of its own. **Never grant permissions to `default`** — you would
be granting them to every pod in the namespace that forgot to specify one.

### 16.3 The token is a projected volume, not a Secret

This changed in **Kubernetes 1.24** and the old behaviour is still in every
tutorial, so know both.

**Before 1.24:** creating a ServiceAccount auto-created a `Secret` of type
`kubernetes.io/service-account-token` holding a JWT that **never expired**. The
Secret was mounted into pods.

**From 1.24:** no Secret is created. The kubelet requests a token from the
**TokenRequest API** and mounts it through a **projected volume**:

```yaml
volumes:
  - name: kube-api-access-xxxxx
    projected:
      sources:
        - serviceAccountToken:
            path: token
            expirationSeconds: 3607
        - configMap:
            name: kube-root-ca.crt        # so the pod can verify the API server
        - downwardAPI:
            items:
              - path: namespace
                fieldRef: {fieldPath: metadata.namespace}
```

mounted at:

```
/var/run/secrets/kubernetes.io/serviceaccount/
    token        the JWT
    ca.crt       the cluster CA (CKA 13)
    namespace    which namespace this pod is in
```

Four properties of the modern token, all of which matter:

| Property | Consequence |
|---|---|
| **time-limited** (~1 hour) | a leaked token expires |
| **auto-rotated by the kubelet** | the file's contents change under the running process |
| **audience-bound** (`aud`) | it is only accepted by the API server, not by your other services |
| **bound to the pod** | deleting the pod invalidates the token immediately |

> **Read the token file on every use, not once at startup.** The kubelet
> rewrites it and a program that cached the contents will start getting `401`s
> about fifty minutes in. Every official client library already does this;
> hand-rolled `curl` scripts are where this bites.

`describe serviceaccount` shows `Tokens: <none>` on a modern cluster. **That is
correct, not broken** — there is no Secret to list.

### 16.4 Getting a token for something outside the cluster

For CI, a monitoring system, or a dashboard you are logging into by hand:

```bash
kubectl create token dashboard-sa
kubectl create token dashboard-sa --duration=24h
```

It prints a JWT and **stores nothing**. There is no object to find later, and no
way to revoke that specific token short of deleting the ServiceAccount.

Use it as a bearer token:

```bash
curl -H "Authorization: Bearer $TOKEN" --cacert ca.crt https://<apiserver>/api/v1/namespaces/default/pods
```

A JWT is three base64url segments separated by dots. Decode the middle one:

```bash
kubectl create token dashboard-sa | cut -d. -f2 | base64 -d 2>/dev/null | jq
```

```json
{
  "aud": ["https://kubernetes.default.svc.cluster.local"],
  "exp": 1755700000,
  "iss": "https://kubernetes.default.svc.cluster.local",
  "kubernetes.io": {
    "namespace": "cka16",
    "serviceaccount": {"name": "dashboard-sa", "uid": "..."}
  },
  "sub": "system:serviceaccount:cka16:dashboard-sa"
}
```

**`sub` is the username RBAC binds to.** Everything in 16.1 is visible right
there in the payload.

> The payload is **signed, not encrypted** — anyone holding the token can read
> its claims. That is fine; the signature is what makes it unforgeable, and it
> was made with `sa.key` ([CKA 13](../13-tls-in-kubernetes/)), not with the
> cluster CA.

### 16.5 Turning the mount off

A pod that never calls the API should not carry a credential for it:

```yaml
# at the ServiceAccount -- applies to every pod using it
automountServiceAccountToken: false

# at the pod -- applies to this pod only
spec:
  automountServiceAccountToken: false
```

**The pod-level setting wins** when the two disagree, in both directions: a pod
can opt in where the ServiceAccount opted out, and out where it opted in.

This is real hardening, not theatre. A token mounted into a compromised pod is a
credential the attacker did not have to steal — and the `default` ServiceAccount
in a namespace where somebody once granted a convenience permission is exactly
how that becomes an escalation.

### 16.6 The legacy path, and why it still exists

You can still create a long-lived token by hand:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: dashboard-sa-token
  annotations:
    kubernetes.io/service-account.name: dashboard-sa
type: kubernetes.io/service-account-token
```

A controller fills in `data.token` with a JWT that has **no expiry**.

It exists for tools that cannot refresh a token — some CI systems, some older
operators. It is the wrong default: a token that never expires is a permanent
credential sitting in etcd, readable by anyone with `get secrets` in that
namespace, and invisible in any rotation report.

**If a task says "create a token that does not expire", this is the answer.** If
a task says "give this application access to the API", the answer is a
ServiceAccount on the pod and no Secret at all.

---

## Part 2 - Hands-on lab

```bash
kubectl create namespace cka16
kubectl config set-context --current --namespace=cka16
```

### Step 1: The `default` ServiceAccount is already there

```bash
kubectl get serviceaccount
kubectl describe serviceaccount default
```

```
Name:                default
Namespace:           cka16
Mountable secrets:   <none>
Tokens:              <none>
```

**`Tokens: <none>` is correct on any cluster from 1.24 onward** (16.3). There is
no Secret because tokens are issued on demand.

```bash
kubectl get secrets            # nothing -- no auto-created token Secret
```

### Step 2: What a pod actually receives

```bash
kubectl apply -f solution/03-pod-default-sa.yaml
kubectl wait --for=condition=Ready pod/uses-default --timeout=60s

kubectl get pod uses-default -o jsonpath='{.spec.serviceAccountName}{"\n"}'
```

`default` — **you did not write that.** The `ServiceAccount` admission
controller injected it, along with the volume:

```bash
kubectl get pod uses-default -o jsonpath='{.spec.volumes}' | tr ',' '\n' | head -20
```

A `projected` volume with three sources. Look inside the container:

```bash
kubectl exec uses-default -- ls -l /var/run/secrets/kubernetes.io/serviceaccount/
```

```
ca.crt      namespace      token
```

Three files, and each has a job (16.3):

```bash
kubectl exec uses-default -- cat /var/run/secrets/kubernetes.io/serviceaccount/namespace; echo
kubectl exec uses-default -- sh -c 'head -c 60 /var/run/secrets/kubernetes.io/serviceaccount/token; echo'
```

Now check the expiry the kubelet asked for:

```bash
kubectl get pod uses-default -o jsonpath='{.spec.volumes[0].projected.sources[0].serviceAccountToken.expirationSeconds}{"\n"}'
```

`3607` — about an hour. **This credential expires**, which is the whole point of
the change in 1.24.

### Step 3: Call the API from inside the pod

```bash
kubectl exec uses-default -- sh -c '
  TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
  curl -s --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
    -H "Authorization: Bearer $TOKEN" \
    https://kubernetes.default.svc/api/v1/namespaces/cka16/pods | head -12'
```

```json
"message": "pods is forbidden: User \"system:serviceaccount:cka16:default\"
            cannot list resource \"pods\" in API group \"\" in the namespace \"cka16\"",
"reason": "Forbidden",
"code": 403
```

**Read the username in that message: `system:serviceaccount:cka16:default`** —
exactly the string from 16.1, assembled from the namespace and the account name.

And read the code: **403, not 401.** The token was accepted; the identity was
established; RBAC then said no. Authentication succeeded
([CKA 13](../13-tls-in-kubernetes/) made the same distinction with a client
certificate).

Note also what made this work at all: `https://kubernetes.default.svc` resolved,
and its certificate verified against the `ca.crt` in the same directory
([CKA 13](../13-tls-in-kubernetes/), 13.7 — that name is in the API server's SAN
list precisely so pods can use it).

### Step 4: Give it an identity that is allowed

```bash
kubectl apply -f solution/01-serviceaccounts.yaml
kubectl apply -f solution/02-rbac.yaml
kubectl apply -f solution/04-pod-dashboard-sa.yaml
kubectl wait --for=condition=Ready pod/uses-dashboard-sa --timeout=60s
```

```bash
kubectl exec uses-dashboard-sa -- sh -c '
  TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
  curl -s --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
    -H "Authorization: Bearer $TOKEN" \
    https://kubernetes.default.svc/api/v1/namespaces/cka16/pods \
    | grep -o "\"name\": \"[a-z0-9-]*\"" | head'
```

The pod list comes back. **One field in the pod spec changed the answer** —
`serviceAccountName: dashboard-sa` — and the RoleBinding did the rest.

Ask the same question without a pod at all:

```bash
kubectl auth can-i list pods --as=system:serviceaccount:cka16:dashboard-sa -n cka16   # yes
kubectl auth can-i list pods --as=system:serviceaccount:cka16:default      -n cka16   # no
kubectl auth can-i delete pods --as=system:serviceaccount:cka16:dashboard-sa -n cka16 # no
```

**`--as` with the full `system:serviceaccount:` string is the fastest way to
test a ServiceAccount's permissions**, and it needs no pod, no token and no
`exec`. Learn this one for the exam.

### Step 5: Decode a token

```bash
TOKEN=$(kubectl create token dashboard-sa)
echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null; echo
```

If `jq` is available:

```bash
echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq
```

Find these four claims and connect each to something in Part 1:

| Claim | Meaning |
|---|---|
| `sub` | `system:serviceaccount:cka16:dashboard-sa` — **what RBAC binds to** |
| `aud` | the API server, and only the API server |
| `exp` | one hour from now by default |
| `kubernetes.io` | namespace and ServiceAccount name and uid |

Now ask for longer, and see the difference:

```bash
kubectl create token dashboard-sa --duration=24h | cut -d. -f2 | base64 -d 2>/dev/null | grep -o '"exp":[0-9]*'
```

Compare a **pod-bound** token with a **standalone** one:

```bash
kubectl exec uses-dashboard-sa -- cat /var/run/secrets/kubernetes.io/serviceaccount/token \
  | cut -d. -f2 | base64 -d 2>/dev/null
```

The pod's token carries a `pod` entry under `kubernetes.io` with the pod's name
and uid. **Delete the pod and that token is dead immediately**, regardless of
`exp`. The token from `kubectl create token` has no such binding and survives
until it expires — which is why the first is safer and the second is what you
paste into a CI system.

### Step 6: Use a token from outside the cluster

This is the CI / monitoring / dashboard case.

```bash
APISERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
mkdir -p /tmp/cka16
kubectl get configmap kube-root-ca.crt -o jsonpath='{.data.ca\.crt}' > /tmp/cka16/ca.crt
TOKEN=$(kubectl create token dashboard-sa --duration=1h)

curl -s --cacert /tmp/cka16/ca.crt -H "Authorization: Bearer $TOKEN" \
  "$APISERVER/api/v1/namespaces/cka16/pods" | grep -o '"name": "[a-z0-9-]*"' | head
```

**No kubeconfig, no certificate, no `kubectl`.** One HTTP header is the entire
credential — which is exactly why the hour-long expiry matters.

Note where the CA came from: the `kube-root-ca.crt` ConfigMap, which Kubernetes
publishes into **every** namespace for precisely this purpose
([CKA 13](../13-tls-in-kubernetes/) C5 flagged it as the thing people forget
during a CA rotation).

Try it against the wrong namespace to see RBAC's scope:

```bash
curl -s --cacert /tmp/cka16/ca.crt -H "Authorization: Bearer $TOKEN" \
  "$APISERVER/api/v1/namespaces/default/pods" | grep -E '"reason"|"code"'
```

`Forbidden`. The RoleBinding is namespaced, so the identity works everywhere and
the permission works in one place.

### Step 7: Do not mount what is not needed

```bash
kubectl apply -f solution/05-pod-no-token.yaml
kubectl wait --for=condition=Ready pod/no-token --timeout=60s

kubectl exec no-token -- ls /var/run/secrets/kubernetes.io/serviceaccount/ 2>&1
```

```
ls: /var/run/secrets/kubernetes.io/serviceaccount/: No such file or directory
```

**The directory does not exist.** Not an empty token, not an invalid one —
nothing was mounted, because `no-token-sa` sets
`automountServiceAccountToken: false`.

```bash
kubectl get pod no-token -o jsonpath='{.spec.volumes}{"\n"}'      # []
```

Now the precedence rule:

```bash
kubectl apply -f solution/06-pod-overrides-sa.yaml
kubectl wait --for=condition=Ready pod/pod-overrides --timeout=60s
kubectl exec pod-overrides -- ls /var/run/secrets/kubernetes.io/serviceaccount/
```

The token **is** there. Same ServiceAccount, opposite result — **the pod-level
setting wins** (16.5). Verify the two settings really do disagree:

```bash
kubectl get sa no-token-sa -o jsonpath='{.automountServiceAccountToken}{"\n"}'      # false
kubectl get pod pod-overrides -o jsonpath='{.spec.automountServiceAccountToken}{"\n"}'  # true
```

### Step 8: A token that never expires

```bash
kubectl apply -f solution/07-legacy-token-secret.yaml
sleep 3
kubectl get secret legacy-sa-token
kubectl describe secret legacy-sa-token
```

```
Type:  kubernetes.io/service-account-token
Data
====
ca.crt:     1099 bytes
namespace:  5 bytes
token:      ...
```

**You supplied only the annotation; a controller filled in the token.** Decode
it and look for what is missing:

```bash
kubectl get secret legacy-sa-token -o jsonpath='{.data.token}' | base64 -d \
  | cut -d. -f2 | base64 -d 2>/dev/null; echo
```

```json
{"iss":"kubernetes/serviceaccount",
 "kubernetes.io/serviceaccount/namespace":"cka16",
 "kubernetes.io/serviceaccount/service-account.name":"legacy-sa",
 "sub":"system:serviceaccount:cka16:legacy-sa"}
```

**No `exp`. No `aud`. No pod binding.** This credential is valid until somebody
deletes the Secret or the ServiceAccount — and nothing anywhere records that it
was ever issued or used.

Compare the two payloads side by side; that difference is the entire argument
for the 1.24 change.

```bash
kubectl delete secret legacy-sa-token
```

### Cleanup

```bash
kubectl delete namespace cka16 --ignore-not-found
kubectl config set-context --current --namespace=default
rm -rf /tmp/cka16
```

---

## Part 3 - Challenges

### C1 - Wire up a monitoring agent

Prometheus needs to read `pods`, `nodes` and `services` in **every** namespace,
and nothing else. Write the complete set of objects, then answer:

1. Why is a `ClusterRoleBinding` required here rather than a `RoleBinding`?
2. Why must the ServiceAccount still live in exactly one namespace?
3. Give the one command that proves the permissions are right, without deploying
   anything.

### C2 - The forbidden pod

A pod logs:

```
pods is forbidden: User "system:serviceaccount:prod:default" cannot list
resource "pods" in API group "" in the namespace "prod"
```

Give the four commands you would run, in order, to find out whether the fix is a
missing `serviceAccountName`, a missing RoleBinding, a RoleBinding in the wrong
namespace, or a typo in the subject. State what each command's output would look
like for each of the four causes.

### C3 - Blast radius

Somebody, fixing an incident at 3am, ran:

```bash
kubectl create clusterrolebinding fix --clusterrole=cluster-admin \
  --group=system:serviceaccounts
```

1. Exactly what does this grant, and to whom?
2. Why is it far worse than `--user=someone`?
3. Give the command that would have found it during a later audit.
4. What is the smallest change that would have made the intent safe?

### C4 - The token that stopped working

A monitoring agent authenticated fine for fifty minutes and then began returning
`401` on every call. It reads the token from
`/var/run/secrets/kubernetes.io/serviceaccount/token`.

Explain the cause precisely, say why restarting the pod "fixes" it for another
fifty minutes, and give the one-line change to the agent that fixes it properly.
Then say what a cluster running 1.23 would have done instead, and why nobody
noticed this class of bug before 1.24.

### C5 - Choose the credential

For each, say whether you would use a **pod-mounted ServiceAccount token**, a
`kubectl create token` **bearer token**, a **legacy Secret token**, or a **client
certificate** — and why:

1. An operator running in-cluster that reconciles CRDs.
2. A GitHub Actions job that runs `kubectl apply` against the cluster.
3. A human administrator.
4. A twelve-year-old monitoring appliance that reads a token from a config file
   at boot and never re-reads it.
5. A `CronJob` that deletes completed Jobs nightly.

---

## Part 4 - Verify

```bash
bash solution/verify.sh
```

Checks: the three ServiceAccounts exist with the right `automountServiceAccountToken`
values; the RoleBinding names the ServiceAccount subject correctly; the default
SA is denied and `dashboard-sa` is allowed by `kubectl auth can-i`; the
`no-token` pod has no projected volume and `pod-overrides` does; a freshly
issued token decodes to the expected `sub` and carries an `exp`.

---

## Part 5 - Exam notes

**Fast paths**

```bash
kubectl create serviceaccount dashboard-sa
kubectl create token dashboard-sa --duration=24h

# attach one to a workload without editing YAML
kubectl set serviceaccount deployment/web dashboard-sa

# bind RBAC to it -- note the --serviceaccount=NS:NAME form
kubectl create rolebinding sa-reads --role=pod-reader \
  --serviceaccount=cka16:dashboard-sa -n cka16
kubectl create clusterrolebinding sa-views --clusterrole=view \
  --serviceaccount=cka16:dashboard-sa

# test permissions with no pod and no token
kubectl auth can-i list pods --as=system:serviceaccount:cka16:dashboard-sa -n cka16
kubectl auth can-i --list --as=system:serviceaccount:cka16:dashboard-sa -n cka16

# which SA does this workload use?
kubectl get pod X -o jsonpath='{.spec.serviceAccountName}{"\n"}'
kubectl get pods -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,SA:.spec.serviceAccountName

# decode any token
echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq
```

**Traps**

- **There is no `User` object.** ServiceAccounts are objects; users are strings.
- **A ServiceAccount is namespaced**, and its username is
  `system:serviceaccount:<ns>:<name>`.
- **`Tokens: <none>` in `describe sa` is normal** from 1.24. No Secret is
  auto-created.
- **`kubectl create token` stores nothing.** There is no object and no way to
  revoke that one token.
- **The mounted token expires and is rotated.** Re-read the file on every use.
- **`403 Forbidden` means the token worked.** `401 Unauthorized` means it did
  not. They point at completely different problems.
- **`serviceAccountName` goes in the pod spec** — inside `template.spec` for a
  Deployment, not next to `replicas`. It is also **immutable on a bare pod**.
- **The pod-level `automountServiceAccountToken` beats the ServiceAccount's**,
  in both directions.
- **Never grant permissions to `default`** — every pod that forgot to name a
  ServiceAccount gets them.
- **`system:serviceaccounts` is every ServiceAccount in the cluster.** Binding
  anything to it is almost always wrong.
- In a RoleBinding, the subject is `kind: ServiceAccount` **with a `namespace`
  field** — not `kind: User` with the long string, though both are accepted.
- `sa` is the short name; `kubectl get sa` works.

---

**Previous:** [CKA 15 — Certificates API and Authorization Modes](../15-certificates-api-and-authorization/)
**Next: CKA 17 — Image Security and Security Contexts** *(not yet built — see [CURRICULUM.md](../CURRICULUM.md))*
