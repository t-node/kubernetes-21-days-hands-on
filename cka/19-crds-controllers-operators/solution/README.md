# CKA 19 solution

## Challenge answers

### C1 - Design a CRD

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: backups.ops.example.com          # <plural>.<group>, exactly
spec:
  group: ops.example.com
  scope: Cluster
  names:
    kind: Backup
    plural: backups
    singular: backup
    shortNames: ["bk"]
  versions:
    - name: v1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              required: ["target", "destination"]
              properties:
                target:
                  type: string
                  enum: ["daily", "weekly", "monthly"]
                retentionDays:
                  type: integer
                  minimum: 1
                  maximum: 365
                  default: 30
                destination:
                  type: string
                  pattern: '^s3://.+'
            status:
              type: object
              properties:
                phase:   {type: string}
                lastRun: {type: string, format: date-time}
      additionalPrinterColumns:
        - {name: Target,    type: string,  jsonPath: .spec.target}
        - {name: Retention, type: integer, jsonPath: .spec.retentionDays}
        - {name: Phase,     type: string,  jsonPath: .status.phase}
        - {name: Age,       type: date,    jsonPath: .metadata.creationTimestamp}
      subresources:
        status: {}
```

**If it must be namespaced instead:** `scope: Namespaced`, and that is the only
line — but **you cannot make that edit on a live CRD**. `scope` is immutable;
the API server rejects the update. Changing it means deleting the CRD and
recreating it, and **deleting a CRD deletes every object of that kind**
(19.3, step 9). So the migration is: export everything
(`kubectl get backups -o yaml > backups.yaml`), delete the CRD, apply the new
one, add a `namespace:` to every exported object, re-apply. There is an outage
in the middle during which the resource does not exist.

**Decide `scope` before anyone uses the CRD.** The rule of thumb: namespaced
unless the resource genuinely describes something cluster-wide *and* you want
RBAC on it to be cluster-wide too. `Backup` as written is cluster-scoped, which
means any namespace's RBAC cannot restrict it — usually the wrong choice for a
multi-tenant platform.

### C2 - The field that vanished

```bash
# 1. what was actually stored?
kubectl get <kind> <name> -o jsonpath='{.spec}{"\n"}'

# 2. what does the schema permit?
kubectl explain <kind>.spec --recursive

# 3. re-apply with strict validation
kubectl apply -f theirfile.yaml --validate=strict
```

| Command | What it shows |
|---|---|
| 1 | `replicaCount` is **absent** from the stored object, or `replicas` is present with the default value |
| 2 | the schema declares `replicas`, not `replicaCount` — the field they used does not exist |
| 3 | `ValidationError(...): unknown field "replicaCount"` — the error the original apply never produced |

**The cause is pruning** (19.3): fields not in the schema are deleted on the way
in, silently, so `kubectl apply` reports success on a manifest that was partly
discarded.

**Fix the colleague can apply today:** use the correct field name, and add
`--validate=strict` to their workflow (or `kubectl diff -f` before applying,
which shows what the server would actually store).

**Fix the CRD author should make:** the schema is too permissive at the object
level. Setting

```yaml
            spec:
              type: object
              additionalProperties: false     # via the structural-schema rules
```

is not how CRDs express this — pruning is already the mechanism — so the real
author-side fixes are:

- **make required fields `required`**, so an object missing `replicas` is
  rejected rather than defaulted into something surprising
- **do not silently default a field whose absence is probably a mistake**; a
  default of 1 for `replicas` turns a typo into a working-but-wrong deployment
- **publish `description:` strings in the schema**, so `kubectl explain` answers
  the question before it becomes a ticket

The deeper point: **a permissive schema plus generous defaults converts user
errors into silent misconfiguration.** That is a design choice, and it is worth
making deliberately.

### C3 - Version migration

**1. What changes, and in what order**

```yaml
  versions:
    - name: v1alpha1
      served: true
      storage: true        # step 1: unchanged
      schema: {...}
    - name: v1
      served: true         # step 1: ADD, served but not storage
      storage: false
      schema: {...}
```

then, as a **separate** apply:

```yaml
    - name: v1alpha1
      served: true
      storage: false       # step 2: flip
    - name: v1
      served: true
      storage: true
```

**Two applies, not one.** Add the new version as served-only first so clients can
start using `v1` while everything on disk is still `v1alpha1`. Only when that is
proven do you move the storage version. Doing both at once is usually fine and
gives you nothing to roll back to.

**2. What happens to objects already in etcd**

**Nothing.** Flipping `storage` changes where *future* writes go. Objects
written as `v1alpha1` stay as `v1alpha1` bytes in etcd and are converted to `v1`
on read. They are rewritten only when something updates them.

To force it — the same technique as re-encrypting Secrets in
[CKA 09](../../09-encryption-at-rest/):

```bash
kubectl get <plural> -A -o json | kubectl replace -f -
```

Read every object, write it back unchanged; each write goes through the new
storage version.

**3. `status.storedVersions`**

```bash
kubectl get crd NAME -o jsonpath='{.status.storedVersions}{"\n"}'
```

```
["v1alpha1","v1"]
```

**The API server maintains this list of every version any object is still stored
as**, and it is the reason you cannot simply drop `v1alpha1` from the CRD: while
that string is present, some object on disk may still be encoded that way, and
removing the version would make it unreadable. The API server refuses the edit.

The sequence is therefore: flip storage → rewrite every object (step 2) →
**remove `v1alpha1` from `status.storedVersions`** (a status subresource patch on
the CRD) → then remove the version from `spec.versions`.

**This is the same shape as the key rotation in [CKA 09](../../09-encryption-at-rest/)**:
add the new form, make it primary, rewrite everything, only then remove the old
form. Removing the old form before the rewrite loses data in both cases.

**4. When a conversion webhook is required**

The default `conversion: {strategy: None}` means **the same object is served
under both versions with only the `apiVersion` string changed**. That is
sufficient when the versions are structurally identical — you are promoting
`v1alpha1` to `v1` without changing any field.

You need `strategy: Webhook` when the schemas genuinely differ: a field was
renamed, a scalar became a list, two fields merged into one. Then something has
to *translate*, and that something is a webhook you deploy, with TLS and a CA
bundle, exactly like [CKA 07](../../07-admission-controllers/).

**How to avoid one**, and this is what most projects actually do: make the new
version **additive only**. Add fields, never rename or remove them; deprecate old
fields by ignoring them rather than deleting them. Additive changes need no
conversion, and a webhook you never wrote cannot break your CRD at 3am.

### C4 - The object that will not delete

**The state:** the object has a **`deletionTimestamp`** set and a non-empty
**`metadata.finalizers`** list. The API server accepted the delete, stamped the
timestamp, and stopped. It will not remove the object until every finalizer is
gone (19.6). Meanwhile the object is visible, readable, and **immutable in every
way except finalizer removal**.

**The one field to look at:**

```bash
kubectl get flightticket stuck -o jsonpath='{.metadata.finalizers}{"\n"}'
kubectl get flightticket stuck -o jsonpath='{.metadata.deletionTimestamp}{"\n"}'
```

**Why deleting it again does nothing:** the delete already happened. A second
`kubectl delete` is a no-op against an object that is already terminating — it
returns immediately or hangs on the same wait. There is nothing left to request.

**Diagnosis:**

```bash
# 1. which finalizer, and therefore whose responsibility?
kubectl get flightticket stuck -o jsonpath='{.metadata.finalizers}{"\n"}'

# 2. is the controller that owns it even running?
kubectl get deploy -A | grep -i flight
kubectl logs -n cka19 -l app=flight-controller --tail=50

# 3. what is it failing on?
kubectl describe flightticket stuck | tail -20
```

**The correct fix is to make the controller finish its job** — restart it, fix
its credentials, restore its network access to whatever external system it is
trying to clean up. It then removes its own finalizer and the object disappears
on its own. In the common case the controller was uninstalled while its objects
still existed, and **reinstalling it briefly is the cleanest resolution**.

**The escape hatch:**

```bash
kubectl patch flightticket stuck --type=merge -p '{"metadata":{"finalizers":null}}'
```

The object is deleted immediately.

**What it costs:** you have skipped the cleanup the finalizer existed to perform.
The Kubernetes object is gone; **whatever it represented is not**. A real
booking is still booked, a cloud load balancer is still provisioned and still
billing, an external DNS record still points somewhere, a volume still exists in
the storage array. Nothing in the cluster now records that it ever existed, so
nobody will find it later.

**Force-removing a finalizer converts a visible problem into an invisible one.**
Do it when you know the external resource is already gone or does not matter —
and when you do it in anger, write down what you orphaned.

### C5 - Should this be a CRD?

| # | Case | Answer | Why |
|---|---|---|---|
| 1 | per-team resource quotas | **neither** — use `ResourceQuota` | it already exists |
| 2 | `kind: PostgresCluster` | **CRD + controller** | the textbook case |
| 3 | feature flags, changed hourly | **neither** — a feature-flag service | see below |
| 4 | which version is deployed where | **neither** — that is Git | see below |
| 5 | firewall rules for an external appliance | **CRD + controller** | legitimate, with caveats |

**1** is the trap of building what you already have. A platform team wanting
consistent quotas needs `ResourceQuota` plus something that applies it to every
namespace — a policy engine, a namespace-provisioning pipeline, or a small
controller that watches Namespaces. **The custom resource would just be a
`ResourceQuota` with a different name.** Before writing a CRD, check
`kubectl api-resources` for what already exists.

**2** is what CRDs are for. A `PostgresCluster` has a spec developers care about
(version, size, backup schedule), a lifecycle a human would otherwise run by
hand, and status worth surfacing. Every managed-database operator is this.

**5** is legitimate — encoding external state as Kubernetes objects gives you
RBAC, audit, GitOps and drift correction for free — with two caveats worth
saying: the controller must be **idempotent** and must handle the appliance
being unreachable without corrupting state, and you need **finalizers** (19.6),
or deleting the resource leaves the rule in place on the appliance forever.

**3 is the one that is a bad idea for a reason unrelated to whether it works.**
It works fine. The problem is **etcd**. Feature flags change many times a day,
often per-user or per-request; every change is a write to etcd, replicated to
every control-plane node, delivered to every watcher, and **retained in the
object's resource version history**. etcd is a coordination store sized for
cluster state that changes occasionally — not a high-write configuration
database. Using it that way degrades the **entire cluster**, including the API
server's own latency, and the blast radius of the mistake is not the feature-flag
system. Flags belong in a purpose-built service (LaunchDarkly, Unleash, or a
Redis key) that the application reads directly.

The rule this suggests: **a CRD is for state that describes desired
infrastructure and changes rarely.** If it changes more than a few times an hour
per object, or if there could be a hundred thousand of them, it does not belong
in the API server.

**4** fails a different test. "Which version is deployed where" is a **fact you
can derive**, not a desired state to declare: it is in Git, and in the live
Deployments. A CRD recording it creates a second source of truth that will
disagree with the first, and nothing reconciles the two. **If a controller cannot
act on it, it is data, not a resource** — and data belongs in a database, a
dashboard, or a label on the object it describes.

---

## Files

| File | Purpose |
|---|---|
| `01-crd.yaml` | the CRD: schema, defaults, enum, printer columns, status subresource |
| `02-ticket.yaml` | a valid FlightTicket |
| `03-ticket-invalid-BAD.yaml` | three schema violations at once |
| `04-ticket-typo.yaml` | valid, and quietly pruned |
| `05-controller.yaml` | ServiceAccount, ClusterRole, binding, ConfigMap, Deployment |
| `controller/reconcile.sh` | the control loop -- observe, diff, act, report |
| `deploy-controller.sh` | loads the script into the ConfigMap and rolls the Deployment |
| `verify.sh` | checks every claim in Part 4 |

> **Run `verify.sh` before step 9.** Deleting the CRD removes every object it
> checks.

---

## Notes on the controller

**It is a real controller and a bad one**, deliberately. What it gets right:

- **Idempotent.** The confirmation code is derived from the object's UID, so
  reconciling the same ticket twice produces the same answer. Real controllers
  are restarted constantly — by rollouts, node drains, crashes — and must
  converge to the same state every time.
- **Reports through the status subresource**, with `flighttickets/status` as a
  separate RBAC rule from `flighttickets`.
- **Sets owner references** on what it creates, so cleanup is the garbage
  collector's job rather than code that can be skipped.
- **Least privilege**: it can `get`/`list`/`watch` tickets and cannot modify
  their spec.

What a Go controller with `client-go` would do instead:

| This | A real one |
|---|---|
| `kubectl get` every 5s | an **informer** — one watch, a shared local cache, events on change |
| a `for` loop over everything | a **workqueue** — only changed objects, deduplicated |
| retry on the next tick | **exponential backoff** per item |
| `replicas: 1` and hope | **leader election**, so several replicas are safe |
| no error handling | requeue with backoff, and conditions written into `.status` |

The polling loop is the honest weakness: at five seconds and a full list every
tick, it is fine for ten objects and would flatten an API server at ten
thousand. **That gap — between "a loop that reconciles" and "a loop that
reconciles at scale" — is what `controller-runtime` and Kubebuilder exist to
close**, and it is why nobody ships production controllers in shell.

Reading `reconcile.sh` is still the fastest way to understand what all that
machinery is *for*.
