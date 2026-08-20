# Day 19 — RBAC: Role-Based Access Control

**Time:** 75-90 minutes
**Prerequisites:** Day 03 (namespaces), Day 10 (secrets)

On Day 10 you established that a Secret is only as safe as the RBAC around it.
Today you build that RBAC: a read-only intern, a namespace admin, and a
least-privilege identity for an application.

---

## Part 1 - Concepts

### 19.1 Authentication vs authorisation

Every request to the API server passes three gates:

```
request ──▶ [1 Authentication] ──▶ [2 Authorisation] ──▶ [3 Admission] ──▶ etcd
             WHO are you?           MAY you do this?      SHOULD this be
                                                          allowed/mutated?
```

**RBAC is gate 2 only.** Gate 1 — proving identity — is handled elsewhere:
client certificates, OIDC (Google, Okta, Entra), cloud IAM (EKS maps IAM
identities to Kubernetes users), or ServiceAccount tokens.

**Kubernetes has no User object.** You cannot `kubectl create user`. Users and
groups are just *strings* that the authenticator asserts — the `CN` of a client
certificate, a claim in an OIDC token. RBAC then binds permissions to those
strings. This surprises almost everyone, and it is a favourite interview
question.

ServiceAccounts, by contrast, **are** real API objects — they are identities for
*pods*, not for people.

> **RBAC is one of five authorization modes.** The others are Node, ABAC,
> Webhook, and AlwaysAllow/AlwaysDeny, set together on the API server with
> `--authorization-mode=Node,RBAC`. If that flag is absent it defaults to
> **AlwaysAllow** and every RBAC rule in this day becomes decorative.
> [CKA 05](../../cka/15-certificates-api-and-authorization/) covers the chain.

### 19.2 The four objects

| Object | Scope | Says |
|---|---|---|
| **Role** | namespace | what may be done, **in this namespace** |
| **ClusterRole** | cluster | what may be done, **cluster-wide** or to cluster-scoped resources |
| **RoleBinding** | namespace | grants a Role **or** a ClusterRole, **within this namespace** |
| **ClusterRoleBinding** | cluster | grants a ClusterRole **everywhere** |

The combination that catches people out:

> **A RoleBinding may reference a ClusterRole.** The permissions are then
> granted **only within the RoleBinding's namespace**.

That is the standard pattern: define `view` / `edit` / `admin` once as
ClusterRoles, then bind them per namespace with RoleBindings. Kubernetes ships
exactly those as built-ins.

| | Role | ClusterRole |
|---|---|---|
| RoleBinding | permissions in that namespace | permissions in **that namespace only** |
| ClusterRoleBinding | **invalid** | permissions **everywhere** |

### 19.3 Anatomy of a Role

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: devboard
  name: viewer
rules:
  - apiGroups: [""]                       # "" = the CORE group (pods, services...)
    resources: ["pods", "services", "configmaps"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]                   # deployments live in the apps group
    resources: ["deployments", "replicasets", "statefulsets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods/log"]               # SUBRESOURCE: logs are separate!
    verbs: ["get"]
```

Four things to internalise:

1. **`apiGroups: [""]`** is the core group — pods, services, configmaps,
   secrets, nodes, namespaces. Not a typo, not a wildcard.
2. **`resources` uses the plural, lowercase API name**: `deployments`, not
   `Deployment`. Get it from `kubectl api-resources`.
3. **Subresources are separate permissions.** `pods` does not include
   `pods/log`, `pods/exec`, `pods/portforward`. Someone who can `get pods` still
   cannot read logs unless you grant `pods/log`.
4. **RBAC is purely additive.** There are no deny rules. Permissions accumulate
   across every binding that applies to you. To take something away you remove a
   binding — you cannot subtract.

The verbs:

| Verb | HTTP |
|---|---|
| `get` | GET one object |
| `list` | GET a collection |
| `watch` | GET a stream of changes |
| `create` | POST |
| `update` | PUT |
| `patch` | PATCH |
| `delete` | DELETE one |
| `deletecollection` | DELETE many |

`get` and `list` are distinct: `get` alone lets you fetch a named object but not
enumerate them. And `kubectl get pods` needs **`list`**, not `get` — a common
source of confusion.

### 19.4 Subjects

```yaml
subjects:
  - kind: User                                    # a string from the authenticator
    name: intern
    apiGroup: rbac.authorization.k8s.io
  - kind: Group                                   # also a string
    name: developers
    apiGroup: rbac.authorization.k8s.io
  - kind: ServiceAccount                          # a REAL object
    name: devboard-reader
    namespace: devboard                           # required for ServiceAccounts
```

Note that `ServiceAccount` subjects take a `namespace` and no `apiGroup`, while
`User` and `Group` take an `apiGroup` and no namespace. Getting this wrong is a
frequent YAML error.

The system also provides virtual groups:

| Group | Contains |
|---|---|
| `system:authenticated` | anyone who authenticated at all |
| `system:unauthenticated` | anonymous requests |
| `system:serviceaccounts` | every ServiceAccount |
| `system:serviceaccounts:devboard` | every ServiceAccount in `devboard` |

### 19.5 The built-in ClusterRoles

Do not write these from scratch — bind them:

| ClusterRole | Grants |
|---|---|
| `view` | read-only on most namespaced resources, **excluding Secrets** |
| `edit` | `view` plus create/update/delete on most resources; can read Secrets |
| `admin` | `edit` plus managing Roles and RoleBindings in the namespace |
| `cluster-admin` | **everything, everywhere.** Grant almost never |

```bash
kubectl get clusterroles | grep -vE "^system:"
kubectl describe clusterrole view | head -30
```

Note that **`view` deliberately excludes Secrets**, precisely because reading a
Secret is reading a credential. Remember that from Day 10.

### 19.6 ServiceAccounts: identity for pods

Every pod runs as a ServiceAccount — the namespace's `default` one if you do not
say otherwise, and `default` has **no permissions**, which is correct.

```yaml
spec:
  serviceAccountName: devboard-reader
  automountServiceAccountToken: true      # false if the pod never calls the API
```

Since Kubernetes 1.24, tokens are **projected, short-lived and audience-bound**,
issued by the kubelet and rotated automatically. Creating a ServiceAccount no
longer creates a long-lived Secret.

**Three rules worth stating in an interview:**

1. One ServiceAccount **per workload**, never a shared one.
2. Set `automountServiceAccountToken: false` on every pod that does not call the
   API — which is most of them, including all three DevBoard tiers.
3. Never bind `cluster-admin` to a ServiceAccount. Anyone who can exec into that
   pod owns your cluster.

### 19.7 `kubectl auth can-i` — the tool that ends the guessing

```bash
kubectl auth can-i create deployments -n devboard
kubectl auth can-i delete pods -n devboard --as=intern
kubectl auth can-i '*' '*' --as=system:serviceaccount:devboard:devboard-admin
kubectl auth can-i --list -n devboard --as=intern
```

`--as` is **user impersonation**. It requires the `impersonate` permission,
which cluster-admin has — so as an admin you can test any identity's permissions
without ever logging in as them. This is how you verify RBAC, and it is the
single most useful command of the day.

---

## Part 2 - Hands-on lab

### Step 1: See what you currently are

```bash
kubectl auth whoami
kubectl auth can-i '*' '*'                 # yes -- you are cluster-admin on kind
kubectl auth can-i --list | head -20
```

kind gives you a client certificate with the group `system:masters`, which is
bound to `cluster-admin`. That is why nothing has been denied for 18 days.

### Step 2: Create ServiceAccounts

```bash
kubectl apply -f solution/01-serviceaccounts.yaml
kubectl get serviceaccounts -n devboard
kubectl describe serviceaccount devboard-intern -n devboard
```

Note: **no Secret is listed.** Pre-1.24 there would have been an auto-created
token Secret. Now tokens are projected into pods on demand.

Prove they start with nothing:

```bash
kubectl auth can-i list pods -n devboard \
  --as=system:serviceaccount:devboard:devboard-intern
# no
```

The impersonation format is worth memorising:
**`system:serviceaccount:<namespace>:<name>`**.

### Step 3: The read-only intern

```bash
kubectl apply -f solution/02-role-viewer.yaml
kubectl apply -f solution/03-rolebinding-intern.yaml

kubectl describe role devboard-viewer -n devboard
kubectl describe rolebinding devboard-intern-viewer -n devboard
```

Now test it — this is the satisfying part:

```bash
SA=system:serviceaccount:devboard:devboard-intern

kubectl auth can-i list   pods        -n devboard --as=$SA    # yes
kubectl auth can-i get    pods/log    -n devboard --as=$SA    # yes
kubectl auth can-i list   deployments -n devboard --as=$SA    # yes
kubectl auth can-i create deployments -n devboard --as=$SA    # no
kubectl auth can-i delete pods        -n devboard --as=$SA    # no
kubectl auth can-i get    secrets     -n devboard --as=$SA    # no  <- important
kubectl auth can-i create pods/exec   -n devboard --as=$SA    # no  <- important
kubectl auth can-i list   pods        -n default  --as=$SA    # no  <- namespace scoped
```

Two of those matter more than the rest:

- **`get secrets: no`** — an intern who could read Secrets could read your
  database password. Day 10's whole point.
- **`create pods/exec: no`** — `exec` is a *write* on a subresource. Without it,
  someone cannot shell into a pod and read its environment, which would bypass
  the Secret restriction entirely.

Run the whole list at once:

```bash
kubectl auth can-i --list -n devboard --as=$SA
```

### Step 4: See it actually deny a real command

```bash
kubectl apply -f solution/04-test-pods.yaml
kubectl wait --for=condition=Ready pod/rbac-intern -n devboard --timeout=90s

# reading works
kubectl exec -n devboard rbac-intern -- \
  kubectl get pods -n devboard

# writing does not
kubectl exec -n devboard rbac-intern -- \
  kubectl delete pod rbac-intern -n devboard
```

```
Error from server (Forbidden): pods "rbac-intern" is forbidden:
User "system:serviceaccount:devboard:devboard-intern" cannot delete resource
"pods" in API group "" in the namespace "devboard"
```

**Read that error format carefully** — it names the user, the verb, the
resource, the API group and the namespace. It tells you exactly which rule to
add. You will see this error for the rest of your career.

Try the secret too:

```bash
kubectl exec -n devboard rbac-intern -- \
  kubectl get secret devboard-secrets -n devboard
# Forbidden
```

### Step 5: The namespace admin

```bash
kubectl apply -f solution/05-role-admin.yaml
kubectl apply -f solution/06-rolebinding-admin.yaml

SA_ADMIN=system:serviceaccount:devboard:devboard-admin

kubectl auth can-i create deployments -n devboard --as=$SA_ADMIN   # yes
kubectl auth can-i delete pods        -n devboard --as=$SA_ADMIN   # yes
kubectl auth can-i get    secrets     -n devboard --as=$SA_ADMIN   # yes
kubectl auth can-i create pods/exec   -n devboard --as=$SA_ADMIN   # yes
kubectl auth can-i delete namespaces               --as=$SA_ADMIN   # NO
kubectl auth can-i list   pods        -n kube-system --as=$SA_ADMIN # NO
kubectl auth can-i list   nodes                     --as=$SA_ADMIN  # NO
```

Full power **inside `devboard`**, nothing outside it. That is the shape of a
team-level permission grant, and it is why namespaces plus RBAC are how
multi-team clusters work.

Note `nodes` is denied even for the admin: nodes are **cluster-scoped**, so a
namespaced Role cannot possibly grant access to them. Day 03's scoping lesson
resurfacing.

### Step 6: Bind a built-in ClusterRole with a RoleBinding

Do not write a viewer Role by hand in real life — bind the built-in one:

```bash
kubectl apply -f solution/07-rolebinding-builtin-view.yaml

SA_AUD=system:serviceaccount:devboard:devboard-auditor
kubectl auth can-i list pods    -n devboard --as=$SA_AUD    # yes
kubectl auth can-i get  secrets -n devboard --as=$SA_AUD    # NO (view excludes secrets)
kubectl auth can-i list pods    -n default  --as=$SA_AUD    # NO (RoleBinding is namespaced)
```

**A ClusterRole granted through a RoleBinding applies only in that namespace.**
That is the most useful RBAC pattern there is: define permissions once
cluster-wide, grant them per namespace.

### Step 7: Least privilege for an application

An app that needs to read its own ConfigMaps should get exactly that and nothing
else:

```bash
kubectl apply -f solution/08-app-serviceaccount.yaml
kubectl wait --for=condition=Ready pod/config-reader -n devboard --timeout=90s

kubectl exec -n devboard config-reader -- \
  kubectl get configmap devboard-config -n devboard

kubectl exec -n devboard config-reader -- \
  kubectl get secret devboard-secrets -n devboard          # Forbidden
kubectl exec -n devboard config-reader -- \
  kubectl get pods -n devboard                             # Forbidden
```

One ServiceAccount, one Role, one verb on one resource. That is least privilege
in practice.

### Step 8: Turn off token mounting where it is not needed

None of the three DevBoard tiers calls the Kubernetes API, so none of them needs
a token:

```bash
kubectl get pods -n devboard -l app=backend \
  -o jsonpath='{.items[0].spec.automountServiceAccountToken}{"\n"}'

kubectl exec -n devboard deploy/backend -- \
  ls /var/run/secrets/kubernetes.io/serviceaccount/ 2>&1 | head -3
```

If the Day 12 manifests are applied, `automountServiceAccountToken: false` is
already set and that path does not exist. Free hardening: if an attacker gets
code execution in the container, there is no cluster credential sitting there
for them to find.

Compare with a pod that does mount one:

```bash
kubectl run tokencheck --image=busybox:1.36 -n devboard --restart=Never -- \
  sh -c "ls -la /var/run/secrets/kubernetes.io/serviceaccount/; sleep 60"
sleep 8
kubectl logs tokencheck -n devboard
kubectl delete pod tokencheck -n devboard
```

`ca.crt`, `namespace` and `token` — a working cluster credential, mounted by
default, in a pod that has no use for it.

### Step 9: Real human users

> **This section used to say "read this, do not run it."** There is now a full
> hands-on lab for it: **[CKA 05 — the Certificates API and authorization
> modes](../../cka/15-certificates-api-and-authorization/)** walks the whole
> flow — generate a key, submit a `CertificateSigningRequest`, approve it,
> extract the certificate, build a kubeconfig, and discover the new user is
> authenticated but authorised for nothing. It also covers denying a hostile
> CSR and the five authorization modes RBAC sits inside.
>
> Read the summary below first, then go do it.

#### Real human users, in summary

For people, RBAC binds to strings the authenticator asserts. Creating a
certificate-based user looks like this:

```bash
# 1. the user generates a key and a CSR
openssl genrsa -out intern.key 2048
openssl req -new -key intern.key -out intern.csr -subj "/CN=intern/O=developers"
#                                                        ^^^^^^^ ^^^^^^^^^^^^^
#                                                        User    Group

# 2. submit it to Kubernetes for signing
cat <<EOF | kubectl apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: intern
spec:
  request: $(cat intern.csr | base64 | tr -d '\n')
  signerName: kubernetes.io/kube-apiserver-client
  usages: ["client auth"]
EOF

# 3. an admin approves it
kubectl certificate approve intern

# 4. bind permissions to the CN, then hand back a kubeconfig
kubectl create rolebinding intern-view --clusterrole=view \
  --user=intern -n devboard
```

The `CN` becomes the **User** and each `O` becomes a **Group**. Nothing was
"created" as a user object — RBAC simply matches the string.

**In practice, do not do this.** Certificates cannot be revoked before expiry
(there is no CRL check), so a leaked one is valid until it expires. Real
clusters use **OIDC** (Google, Okta, Entra) or **cloud IAM** — on EKS, an
`aws-auth`/access-entry mapping turns IAM principals into Kubernetes users and
groups. Then you bind Roles to *groups*, and joiners/leavers are handled by your
identity provider rather than by kubectl.

---

## Validate

```bash
kubectl apply -f solution/
SA=system:serviceaccount:devboard:devboard-intern
SA_ADMIN=system:serviceaccount:devboard:devboard-admin

# the intern can read but not write, and cannot touch secrets
kubectl auth can-i list   pods    -n devboard --as=$SA          # yes
kubectl auth can-i delete pods    -n devboard --as=$SA          # no
kubectl auth can-i get    secrets -n devboard --as=$SA          # no

# the admin is powerful inside the namespace and nowhere else
kubectl auth can-i create deployments -n devboard    --as=$SA_ADMIN   # yes
kubectl auth can-i list   pods        -n kube-system --as=$SA_ADMIN   # no

# and prove it end to end
kubectl wait --for=condition=Ready pod/rbac-intern -n devboard --timeout=90s
kubectl exec -n devboard rbac-intern -- kubectl get pods -n devboard
kubectl exec -n devboard rbac-intern -- kubectl delete pod rbac-intern -n devboard 2>&1 | grep -c Forbidden
```

Ready for Day 20 when you can:

1. Explain why there is no User object in Kubernetes.
2. Say what a RoleBinding referencing a ClusterRole grants.
3. Explain why `get secrets` and `create pods/exec` are the two permissions to
   guard most carefully.
4. Write the impersonation string for a ServiceAccount from memory.

---

## Break it

**A. Forget that subresources are separate.**

```bash
kubectl apply -f solution/09-role-pods-only.yaml
SA_P=system:serviceaccount:devboard:devboard-podreader

kubectl auth can-i list pods     -n devboard --as=$SA_P     # yes
kubectl auth can-i get  pods/log -n devboard --as=$SA_P     # NO
```

They can see that a pod exists and is crash-looping, but cannot read the logs
that would explain why. `resources: ["pods"]` does **not** include `pods/log`.

**B. `pods/exec` is a backdoor around every other restriction.**

```bash
kubectl apply -f solution/10-role-exec-danger.yaml
SA_E=system:serviceaccount:devboard:devboard-execer

kubectl auth can-i get    secrets   -n devboard --as=$SA_E   # no
kubectl auth can-i create pods/exec -n devboard --as=$SA_E   # YES
```

They cannot read Secrets through the API — but they can `kubectl exec` into a
pod that has one mounted and `cat` it, or read `/proc/1/environ`. **Granting
`pods/exec` effectively grants everything any pod in that namespace can see.**
Treat it as an admin-level permission.

**C. Wrong apiGroup.**

```bash
kubectl apply -f solution/11-role-wrong-apigroup.yaml
SA_W=system:serviceaccount:devboard:devboard-wrong
kubectl auth can-i list deployments -n devboard --as=$SA_W   # no
```

The Role lists `deployments` under `apiGroups: [""]`, but Deployments live in
`apps`. **The object is accepted without error** — RBAC does not validate that
the resource exists in the group — and simply grants nothing. Silent failure.

```bash
kubectl api-resources | grep -E "^deployments|^pods "
```

**D. RBAC is additive — you cannot deny.**

```bash
kubectl create rolebinding oops-admin --clusterrole=admin \
  --serviceaccount=devboard:devboard-intern -n devboard

kubectl auth can-i delete pods -n devboard --as=$SA     # NOW YES
kubectl auth can-i get secrets -n devboard --as=$SA     # NOW YES
```

The restrictive viewer Role is still bound and did nothing to stop this. **There
are no deny rules in RBAC** — permissions are the union of every binding. To
take access away you must remove bindings.

```bash
kubectl delete rolebinding oops-admin -n devboard
```

**E. cluster-admin on a ServiceAccount.**

```bash
kubectl create clusterrolebinding dangerous \
  --clusterrole=cluster-admin \
  --serviceaccount=devboard:devboard-intern

kubectl auth can-i '*' '*' --as=$SA                     # yes
kubectl auth can-i delete nodes --as=$SA                # yes
```

Any pod using that ServiceAccount, and anyone who can exec into it or exploit an
RCE in it, now owns the entire cluster. This is one of the most common real
misconfigurations, usually added to "make it work" and never removed.

```bash
kubectl delete clusterrolebinding dangerous
```

**F. Audit what actually exists.**

```bash
kubectl get clusterrolebindings -o json | \
  python -c "import sys,json; [print(b['metadata']['name'],'->',[ (s.get('kind'),s.get('name')) for s in b.get('subjects') or []]) for b in json.load(sys.stdin)['items'] if b['roleRef']['name']=='cluster-admin']"
```

Run the equivalent on any cluster you inherit. The list is usually longer than
anyone expects.

---

## Interview questions

<details>
<summary><b>1. How do you create a user in Kubernetes?</b> (trick question)</summary>

You do not - there is no User object and no `kubectl create user`. Users and
groups are strings asserted by the authenticator: the CN and O fields of a
client certificate, claims in an OIDC token, or an IAM identity mapping on a
managed cluster. RBAC then binds permissions to those strings. ServiceAccounts
are different - they are real API objects, and they are identities for pods, not
people.
</details>

<details>
<summary><b>2. Role vs ClusterRole, RoleBinding vs ClusterRoleBinding?</b></summary>

A Role defines permissions within one namespace; a ClusterRole defines them
cluster-wide or over cluster-scoped resources such as nodes and
PersistentVolumes. A RoleBinding grants either kind but always scoped to its own
namespace; a ClusterRoleBinding grants a ClusterRole everywhere. The important
combination is RoleBinding plus ClusterRole: define permissions once, grant them
per namespace - which is exactly how the built-in view, edit and admin roles are
meant to be used.
</details>

<details>
<summary><b>3. Can you write a deny rule in RBAC?</b></summary>

No. RBAC is purely additive - effective permissions are the union of every
binding that applies to a subject, and nothing subtracts. To remove access you
remove bindings. Denial-style policy needs admission control instead: OPA
Gatekeeper, Kyverno, or ValidatingAdmissionPolicy.
</details>

<details>
<summary><b>4. Someone can list pods but not read logs. Why?</b></summary>

Logs are a subresource, `pods/log`, and it is a separate permission from `pods`.
The same applies to `pods/exec`, `pods/portforward`, `pods/status` and
`deployments/scale`. A Role must grant subresources explicitly.
</details>

<details>
<summary><b>5. Which permissions should you guard most carefully?</b></summary>

`get`/`list` on **secrets**, because that is reading credentials directly. And
`create` on **pods/exec**, because shelling into a pod exposes everything that
pod can see - mounted secrets, environment variables, its ServiceAccount token -
which bypasses every other restriction. Also `escalate` and `bind` on RBAC
objects, which let a subject grant themselves more, and the ability to create
pods at all, since a pod can mount any secret in its namespace.
</details>

<details>
<summary><b>6. How does a pod authenticate to the API server?</b></summary>

Through its ServiceAccount. Since 1.24 the kubelet projects a short-lived,
audience-bound token into the pod and rotates it; long-lived token Secrets are no
longer created automatically. The pod presents that token and RBAC evaluates the
identity `system:serviceaccount:<namespace>:<name>`. Pods that never call the
API should set `automountServiceAccountToken: false`.
</details>

<details>
<summary><b>7. How do you test whether a permission is correctly configured?</b></summary>

`kubectl auth can-i <verb> <resource> -n <ns> --as=<user>`, and
`kubectl auth can-i --list` for everything a subject can do. `--as` is
impersonation, which requires the impersonate permission, so as an admin you can
verify any identity without holding its credentials. Test both the allowed and
the denied cases - a rule that grants too much passes the positive test
perfectly.
</details>

<details>
<summary><b>8. How would you give a new team access to their own namespace only?</b></summary>

Create the namespace, then a RoleBinding in it referencing the built-in `admin`
ClusterRole, with the team's OIDC group as the subject. That gives full control
inside the namespace and none outside it. Add a ResourceQuota and LimitRange so
they cannot consume the cluster, and NetworkPolicies if traffic isolation
matters. Bind to a group, never to individuals, so joiners and leavers are
handled by the identity provider.
</details>

<details>
<summary><b>9. How do you audit RBAC on a cluster you have inherited?</b></summary>

Start with every ClusterRoleBinding referencing `cluster-admin` and ask whether
each is still justified. Then look for wildcards - `verbs: ["*"]`,
`resources: ["*"]` - and for bindings to broad groups such as
`system:authenticated`. Check which ServiceAccounts hold cluster-wide
permissions. Tools like `rbac-lookup`, `rakkess` and `kubectl-who-can` make this
much faster, and `kubectl auth can-i --list --as=...` verifies specific
identities.
</details>

<details>
<summary><b>10. What is the difference between RBAC and admission control?</b></summary>

RBAC answers "may this identity perform this verb on this resource kind?" - it
sees the request, not the object's contents. Admission control runs afterwards
and can inspect and even mutate the object: reject a pod running as root, force
resource limits, require a label. So "developers may create pods" is RBAC, while
"pods may not be privileged" is admission control - Pod Security admission,
Kyverno, or Gatekeeper.
</details>

---

## Cheat card

```bash
# who am I, what can I do
kubectl auth whoami
kubectl auth can-i --list -n devboard
kubectl auth can-i create deployments -n devboard

# test someone else (impersonation)
kubectl auth can-i delete pods -n devboard --as=system:serviceaccount:devboard:devboard-intern
kubectl auth can-i --list -n devboard --as=system:serviceaccount:devboard:devboard-intern
kubectl auth can-i list pods --as=jane --as-group=developers

# create quickly (then export to YAML and commit it)
kubectl create serviceaccount ci -n devboard
kubectl create role viewer --verb=get,list,watch --resource=pods,deployments -n devboard
kubectl create rolebinding ci-view --role=viewer --serviceaccount=devboard:ci -n devboard
kubectl create rolebinding team-admin --clusterrole=admin --group=devs -n devboard

kubectl create role r --verb=get --resource=pods -n devboard --dry-run=client -o yaml

# inspect
kubectl get roles,rolebindings -n devboard
kubectl get clusterroles | grep -vE "^system:"
kubectl describe clusterrole view
kubectl get clusterrolebindings -o wide | grep cluster-admin
```

| Want | Do |
|---|---|
| read-only in one namespace | RoleBinding → ClusterRole `view` |
| full control of one namespace | RoleBinding → ClusterRole `admin` |
| read pods cluster-wide | ClusterRoleBinding → a custom ClusterRole |
| an app reading its own ConfigMap | ServiceAccount + Role + RoleBinding |
| a pod that needs no API access | `automountServiceAccountToken: false` |

**Impersonation string:** `system:serviceaccount:<namespace>:<name>`

---

**Next: [Day 20 - Ingress and the Gateway API](../day-20-ingress-and-gateway-api/)**
