# CKA 19 — Custom Resources, Controllers and Operators

**Time:** 90-110 minutes
**Prerequisites:** [CKA 04](../04-imperative-declarative-and-apply/), [CKA 14](../14-kubeconfig-and-the-api/), [CKA 16](../16-service-accounts/)
**Source lectures:** 182, 184, 185

Everything you have created so far — Deployments, Services, PVCs — is a
**resource** stored in etcd, plus a **controller** that watches it and makes the
world match. This assignment shows that both halves are extensible, and that you
can build your own without leaving `kubectl`.

---

## Part 1 - Concepts

### 19.1 A resource is data; a controller is behaviour

```
   kubectl apply -f deployment.yaml
              |
              v
   [ API SERVER ] --> stored in etcd     <-- this is the RESOURCE
              |
              v
   [ DEPLOYMENT CONTROLLER ]             <-- this is the BEHAVIOUR
       watches Deployments
       creates a ReplicaSet
       which creates Pods
```

**Storing a Deployment does nothing on its own.** If you deleted the deployment
controller, `kubectl apply -f deployment.yaml` would still succeed, `kubectl get
deployments` would still list it, and **no pods would ever appear** — exactly the
state [CKA 05](../05-manual-scheduling-and-static-pods/) produced by removing the
scheduler.

Kubernetes is a database with a set of processes that watch it. Both are
replaceable, and both are extensible:

| You add | You get |
|---|---|
| a **CustomResourceDefinition** | a new *kind* you can `apply`, `get` and `delete` |
| a **custom controller** | something that actually happens when you do |
| **both, packaged together** | an **operator** |

### 19.2 Without a CRD, your kind does not exist

```yaml
apiVersion: flights.example.com/v1
kind: FlightTicket
metadata: {name: my-ticket}
spec:
  from: Mumbai
  to: London
  number: 2
```

```
error: resource mapping not found for ... no matches for kind "FlightTicket"
in version "flights.example.com/v1"
```

**The API server refuses to store a kind it has never heard of.** A CRD is how
you tell it.

### 19.3 The anatomy of a CRD

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: flighttickets.flights.example.com     # MUST be <plural>.<group>
spec:
  group: flights.example.com
  scope: Namespaced                            # or Cluster
  names:
    kind: FlightTicket                         # what you write in YAML
    plural: flighttickets                      # the URL path and `kubectl get`
    singular: flightticket
    shortNames: [ft]
    categories: [travel]                       # `kubectl get travel`
  versions:
    - name: v1
      served: true                             # reachable through the API
      storage: true                            # written to etcd in THIS version
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              required: [from, to]
              properties:
                from:   {type: string}
                to:     {type: string}
                number: {type: integer, minimum: 1, maximum: 10}
```

Six things in there earn attention:

**`metadata.name` must be exactly `<plural>.<group>`.** Not a convention — the
API server rejects anything else, and the error is unhelpfully indirect.

**`scope`** decides whether the resource is namespaced (like Pods) or
cluster-wide (like PersistentVolumes and Nodes). Changing it later means
deleting the CRD, which deletes every object of that kind.

**`served` and `storage`.** A CRD may offer several versions at once, but
**exactly one may have `storage: true`** — that is the form written into etcd.
Others are converted on the way in and out. Serving `v1alpha1` and `v1` while
storing only `v1` is how a resource matures without breaking existing manifests.

**The schema is OpenAPI v3, and it is mandatory** in `apiextensions.k8s.io/v1`.
It gives you `required`, `minimum` / `maximum`, `pattern`, `enum` and defaults —
validation the API server enforces before anything is stored.

**Fields not in the schema are silently deleted.** This is called *pruning* and
it surprises everyone: a typo in a field name does not error, it vanishes. Opt
out with `x-kubernetes-preserve-unknown-fields: true`, which you almost never
want.

**`shortNames` and `categories`** are quality-of-life, and free. `ft` for typing;
`categories: [travel]` makes `kubectl get travel` return every resource in that
category at once — the mechanism behind `kubectl get all`.

### 19.4 Printer columns and subresources

Two optional blocks that make a custom resource feel native:

```yaml
      additionalPrinterColumns:
        - name: From
          type: string
          jsonPath: .spec.from
        - name: Status
          type: string
          jsonPath: .status.state
        - name: Age
          type: date
          jsonPath: .metadata.creationTimestamp
      subresources:
        status: {}
```

**`additionalPrinterColumns`** is what `kubectl get flightticket` prints. Without
it you get `NAME` and `AGE` and nothing else.

**`subresources: {status: {}}`** splits the object in two, and the split matters:

| | Written by | How |
|---|---|---|
| `spec` | **the user** — desired state | `kubectl apply` |
| `status` | **the controller** — observed state | `kubectl patch --subresource=status` |

Once the status subresource is enabled, **`kubectl apply` cannot write `status`
at all** — it is silently dropped. And a controller writing status does not bump
`metadata.generation`, so it cannot trigger its own reconcile loop. That
separation is the reason the subresource exists.

`subresources: {scale: {}}` is the other one: it makes `kubectl scale` and
**HPAs** work against your custom resource
([Day 17](../../days/day-17-horizontal-pod-autoscaler/)).

### 19.5 A controller is a loop

```
   for ever:
       observe   -- what resources exist, and in what state?
       diff      -- how does that differ from what the spec asks for?
       act       -- make the difference smaller
       report    -- write what happened into .status
```

That is the whole idea, and it is why Kubernetes is *declarative*: nobody
executes your YAML, something continuously reduces the gap between it and
reality.

Real controllers are written in Go with `client-go`, which supplies **informers**
(a cached, shared watch) and **workqueues** (deduplicated, rate-limited retries).
You would not hand-roll those.

But the *pattern* needs neither Go nor a framework, and in Part 2 you deploy a
working controller written in **bash and `kubectl`**: it watches `FlightTicket`
objects, "books" them against an imaginary airline, writes the confirmation into
`.status`, and creates a child object that is garbage-collected when the ticket
is deleted. Everything a real controller does, minus the performance.

> **The exam does not ask you to write a controller.** It asks you to create
> CRDs, read them, and work with resources whose controllers already exist. This
> assignment builds one anyway, because a CRD only makes sense once you have
> watched something act on it.

### 19.6 Ownership and cleanup

When a controller creates a child object, it stamps an **owner reference**:

```yaml
metadata:
  ownerReferences:
    - apiVersion: flights.example.com/v1
      kind: FlightTicket
      name: my-ticket
      uid: 6f0e...
      blockOwnerDeletion: false
```

**Delete the owner and Kubernetes deletes the children**, through the garbage
collector — no controller code involved. It is the same mechanism that removes
Pods when you delete a ReplicaSet.

Two rules: **owner and child must be in the same namespace** (unless the owner is
cluster-scoped), and a **dangling owner reference deletes the child
immediately** — pointing one at a UID that does not exist is a common way to make
objects vanish mysteriously.

For cleanup that needs *code* — cancelling a real booking through an external
API — you need a **finalizer**:

```yaml
metadata:
  finalizers:
    - flights.example.com/cancel-booking
```

A `delete` on an object with finalizers sets `deletionTimestamp` and **stops**.
The object stays, visible and unchanged, until every finalizer is removed. The
controller does its external cleanup, removes its finalizer, and the object
disappears.

> **This is why an object sometimes will not delete.** It sits in `Terminating`
> because a finalizer is listed and the controller that would remove it is gone.
> The escape is to strip it by hand:
> ```bash
> kubectl patch <kind> <name> --type=merge -p '{"metadata":{"finalizers":null}}'
> ```
> Do that only when you know the external cleanup does not matter, because you
> are deliberately skipping it.

### 19.7 Operators

An **operator** is a CRD plus a controller, packaged and shipped together, that
encodes what a human operator would do to run a specific application: install
it, upgrade it, back it up, restore it, fail over.

```
  kubectl apply -f etcd-operator.yaml
        |
        +--> installs the EtcdCluster CRD
        +--> deploys the controller
        |
  kubectl apply -f my-cluster.yaml        (kind: EtcdCluster, size: 5)
        |
        +--> the controller creates 5 etcd pods, configures peering,
             takes scheduled backups, restores on request
```

**OperatorHub** catalogues them; **Operator Lifecycle Manager (OLM)** installs
and upgrades them. Prometheus, Argo CD, Istio, cert-manager and most database
vendors ship one.

**Nothing here is a new API.** An operator is CRDs plus a Deployment plus RBAC
plus a control loop — the ordinary parts you already know, assembled. That is
the point worth taking away, and it is why you can build one in Part 2 with
`kubectl` and a `while` loop.

---

## Part 2 - Hands-on lab

```bash
kubectl create namespace cka19
kubectl config set-context --current --namespace=cka19
```

### Step 1: The kind does not exist yet

```bash
kubectl apply -f solution/02-ticket.yaml
```

```
error: resource mapping not found for name: "mumbai-london" ... no matches for
kind "FlightTicket" in version "flights.example.com/v1"
ensure CRDs are installed first
```

**The error even tells you the fix.** Confirm nothing knows the name:

```bash
kubectl api-resources | grep -i flight        # nothing
```

### Step 2: Define it

```bash
kubectl apply -f solution/01-crd.yaml
kubectl get crd flighttickets.flights.example.com
kubectl api-resources | grep -i flight
```

```
NAME             SHORTNAMES   APIVERSION                    NAMESPACED   KIND
flighttickets    ft           flights.example.com/v1        true         FlightTicket
```

**It is now a first-class resource.** Everything `kubectl` does works on it,
including the thing that surprises people:

```bash
kubectl explain flightticket.spec
kubectl explain flightticket.spec.number
```

```
FIELD: number <integer>
DESCRIPTION: <empty>
```

**`kubectl explain` reads your schema.** The API server publishes it as OpenAPI,
so documentation, validation and client-side tooling all come from the one
place you wrote it.

```bash
kubectl apply -f solution/02-ticket.yaml
kubectl get flighttickets
kubectl get ft                      # the shortName
kubectl get travel                  # the category
```

```
NAME            FROM     TO       SEATS   STATE   BOOKING   AGE
mumbai-london   Mumbai   London   2                         12s
```

Those columns come from `additionalPrinterColumns` (19.4). `STATE` and `BOOKING`
are empty because **nothing is watching this object** — it is data in etcd and
nothing more.

### Step 3: Validation happens before storage

```bash
kubectl apply -f solution/03-ticket-invalid-BAD.yaml
```

```
The FlightTicket "bad-ticket" is invalid:
* spec.to: Invalid value: "LA": spec.to in body should be at least 3 chars long
* spec.number: Invalid value: 42: spec.number in body should be less than or equal to 10
* spec.class: Unsupported value: "economy++": supported values: "economy", "business", "first"
```

**Every violation at once**, and nothing was stored. That is the OpenAPI schema
being enforced by the API server itself — no webhook, no controller.

Now the defaults you never wrote:

```bash
kubectl get ft mumbai-london -o jsonpath='{.spec}{"\n"}'
kubectl apply -f - <<EOF
apiVersion: flights.example.com/v1
kind: FlightTicket
metadata: {name: minimal, namespace: cka19}
spec: {from: Delhi, to: Dubai}
EOF
kubectl get ft minimal -o jsonpath='{.spec}{"\n"}'
```

```json
{"class":"economy","from":"Delhi","number":1,"to":"Dubai"}
```

**`class` and `number` appeared.** `default:` in the schema is applied by the API
server on create — the same defaulting that gives a Pod its `imagePullPolicy`
([CKA 17](../17-image-security-and-security-contexts/)).

### Step 4: Pruning — the quiet failure

```bash
kubectl apply -f solution/04-ticket-typo.yaml
kubectl get ft typo-ticket -o jsonpath='{.spec}{"\n"}'
```

```json
{"class":"economy","from":"Delhi","number":1,"to":"Singapore"}
```

Look at the file: it asked for `nubmer: 5`. **The field is gone and `number` is
1.** No error, no warning, no event.

```bash
diff <(kubectl get ft typo-ticket -o jsonpath='{.spec}') <(echo "what you wrote")
```

**Unknown fields are pruned, silently** (19.3). The defence is `--dry-run=server`
plus reading back what was actually stored — and a schema strict enough that
typos land outside it. `kubectl apply --validate=strict` catches it client-side:

```bash
kubectl apply -f solution/04-ticket-typo.yaml --validate=strict
```

```
error: error validating "...": ValidationError(FlightTicket.spec): unknown field "nubmer"
```

**`--validate=strict` is worth knowing.** It turns the silent failure into an
error.

```bash
kubectl delete ft typo-ticket minimal
```

### Step 5: Status is not yours to write

```bash
kubectl patch ft mumbai-london --type=merge -p '{"status":{"state":"Booked"}}'
kubectl get ft mumbai-london -o jsonpath='{.status}{"\n"}'
```

Nothing. The status subresource is enabled, so a normal write **drops `status`
entirely** (19.4). The controller's route:

```bash
kubectl patch ft mumbai-london --subresource=status --type=merge \
  -p '{"status":{"state":"Manual","confirmation":"BK-TEST"}}'
kubectl get ft mumbai-london
```

```
NAME            FROM     TO       SEATS   STATE    BOOKING   AGE
mumbai-london   Mumbai   London   2       Manual   BK-TEST   3m
```

**Same object, different endpoint, different permission.** Note in
`solution/05-controller.yaml` that `flighttickets` and `flighttickets/status`
are separate RBAC rules — a controller can be allowed to report without being
allowed to change what it was asked to do.

```bash
kubectl patch ft mumbai-london --subresource=status --type=merge -p '{"status":null}'
```

### Step 6: Give it behaviour

```bash
cat solution/controller/reconcile.sh
```

Read it before deploying — it is forty lines and every one maps to something in
19.5. Then:

```bash
bash solution/deploy-controller.sh
kubectl logs -n cka19 -l app=flight-controller -f &
```

Within seconds:

```
09:14:22 flight-ticket controller starting; polling every 5s
09:14:23 booking cka19/mumbai-london: Mumbai -> London x2 (business) => BK-6F0E1A
09:14:24   status written for cka19/mumbai-london
```

```bash
kubectl get ft
```

```
NAME            FROM     TO       SEATS   STATE    BOOKING     AGE
mumbai-london   Mumbai   London   2       Booked   BK-6F0E1A   6m
```

**The object you created five minutes ago has changed on its own.** Nothing was
applied; a process observed a gap and closed it.

Create another and watch the loop run:

```bash
kubectl apply -f - <<EOF
apiVersion: flights.example.com/v1
kind: FlightTicket
metadata: {name: tokyo-run, namespace: cka19}
spec: {from: Tokyo, to: Seoul, number: 3, class: first}
EOF
sleep 8
kubectl get ft
kubectl get configmap -l flights.example.com/ticket
```

```
NAME                   DATA   AGE
booking-mumbai-london  4      2m
booking-tokyo-run      4      8s
```

**The controller created a child object for each ticket:**

```bash
kubectl get configmap booking-tokyo-run -o jsonpath='{.data}{"\n"}'
```

Prove idempotency — reconciling twice must not book twice:

```bash
kubectl delete pod -n cka19 -l app=flight-controller
sleep 20
kubectl get ft tokyo-run -o jsonpath='{.status.confirmation}{"\n"}'
kubectl logs -n cka19 -l app=flight-controller --tail=5
```

The confirmation is **unchanged** and the fresh controller logged no new
bookings. That is the `if [ "$CONF" != "<none>" ]` guard — and it is why real
controllers derive results from the object rather than from a counter.

### Step 7: Garbage collection

```bash
kubectl get configmap -l flights.example.com/ticket
kubectl get configmap booking-tokyo-run -o jsonpath='{.metadata.ownerReferences}{"\n"}'
```

```json
[{"apiVersion":"flights.example.com/v1","blockOwnerDeletion":false,
  "kind":"FlightTicket","name":"tokyo-run","uid":"..."}]
```

Now delete the ticket and **do not touch the ConfigMap**:

```bash
kubectl delete ft tokyo-run
sleep 5
kubectl get configmap -l flights.example.com/ticket
```

```
NAME                    DATA   AGE
booking-mumbai-london   4      5m
```

**`booking-tokyo-run` is gone.** No controller code deleted it — the garbage
collector saw an owner reference whose target no longer existed (19.6). This is
the same mechanism that removes Pods when you delete a Deployment, available to
anything you build.

Check the controller logs: it never mentioned the deletion. **It does not have
to.**

### Step 8: What an operator adds

You have now built one:

| Piece | File |
|---|---|
| the CRD | `solution/01-crd.yaml` |
| the controller | `solution/05-controller.yaml` + `controller/reconcile.sh` |
| RBAC | inside `05-controller.yaml` |

```bash
kubectl get crd,deployment,clusterrole,clusterrolebinding -A 2>/dev/null | grep -i flight
```

An operator is those three shipped as one artefact, plus lifecycle management
(19.7). To see a real one's shape without installing it:

```bash
kubectl get crd | head -20
```

On a stock kind cluster that list is empty or nearly so. On any real cluster it
is long — cert-manager, Prometheus, Argo CD and the cloud provider's own
controllers all announce themselves there. **`kubectl get crd` is the fastest way
to learn what a strange cluster actually runs.**

### Step 9: Deleting a CRD deletes everything

Do this last, and understand it before you do.

```bash
kubectl get ft
kubectl delete crd flighttickets.flights.example.com
kubectl get ft
```

```
error: the server doesn't have a resource type "ft"
```

**Every FlightTicket in every namespace was deleted with the CRD**, along with
their ConfigMaps through ownership. There is no confirmation prompt and no undo.

> **`kubectl delete crd` is one of the most destructive commands in Kubernetes.**
> Deleting the cert-manager CRD takes every Certificate and Issuer in the
> cluster with it. Check what exists first:
> ```bash
> kubectl get <plural> -A --no-headers | wc -l
> ```

### Cleanup

```bash
kubectl delete clusterrolebinding flight-controller --ignore-not-found
kubectl delete clusterrole flight-controller --ignore-not-found
kubectl delete crd flighttickets.flights.example.com --ignore-not-found
kubectl delete namespace cka19 --ignore-not-found
kubectl config set-context --current --namespace=default
```

---

## Part 3 - Challenges

### C1 - Design a CRD

Write the complete CRD for a `Backup` resource:

- cluster-scoped, group `ops.example.com`, version `v1`
- `spec.target` (required, must be `daily`, `weekly` or `monthly`)
- `spec.retentionDays` (integer, 1–365, default 30)
- `spec.destination` (required, must start with `s3://` — use `pattern`)
- `kubectl get backup` shows target, retention, phase and age
- a controller can write `.status.phase` and `.status.lastRun`
- short name `bk`

Then say what changes if it must be **namespaced** instead, and why that is not
a one-word edit on an existing CRD.

### C2 - The field that vanished

A colleague reports: "I set `spec.replicaCount: 5` on our custom resource, it
applied cleanly, and the controller keeps creating one replica."

Give the three commands that diagnose this and say what each would show. Then
give two independent fixes — one the colleague can apply today and one the CRD
author should make.

### C3 - Version migration

Your CRD serves `v1alpha1` (storage) and you need to add `v1`. Existing objects
in etcd are stored as `v1alpha1`.

1. What must change in the CRD, and in what order?
2. What happens to objects already in etcd when you flip the storage version?
3. What is `status.storedVersions` on the CRD, and why can you not simply delete
   `v1alpha1` once `v1` is the storage version?
4. When is a conversion webhook actually required, and when can you avoid one?

### C4 - The object that will not delete

```bash
kubectl delete flightticket stuck
# hangs, then:
kubectl get flightticket stuck
# NAME    ...   AGE
# stuck   ...   4d
```

Explain precisely what state that object is in, the one field to look at, and
why deleting it again does not help. Give the diagnosis commands, the correct
fix, and the escape hatch — and say what the escape hatch actually costs.

### C5 - Should this be a CRD?

For each, say whether you would model it as a CRD-plus-controller, a
ConfigMap, or neither — and why:

1. Per-team resource quotas that a platform team wants applied consistently.
2. A "database" abstraction where developers request `kind: PostgresCluster` and
   get a provisioned, backed-up instance.
3. Application feature flags, changed several times a day.
4. A record of which version of each service is deployed in each environment.
5. Firewall rules for an appliance outside the cluster.

One of these is a bad idea for a reason unrelated to whether it *could* work.

---

## Part 4 - Verify

```bash
bash solution/verify.sh
```

Checks: the CRD is established with the right names, scope and short name; the
schema rejects out-of-range values and applies defaults; the status subresource
exists and refuses a normal write; the controller is Running, has booked every
ticket, and is idempotent; child ConfigMaps carry owner references and are
garbage-collected when their ticket is deleted.

---

## Part 5 - Exam notes

**Fast paths**

```bash
# what custom resources does this cluster have?
kubectl get crd
kubectl api-resources --api-group=flights.example.com
kubectl api-versions | grep flights

# is a CRD healthy?
kubectl get crd NAME -o jsonpath='{.status.conditions[?(@.type=="Established")].status}{"\n"}'

# read the schema you or someone else wrote
kubectl explain flightticket --recursive
kubectl explain flightticket.spec.number

# find every object of a custom kind, everywhere
kubectl get flighttickets -A

# a controller writes status through the subresource, never through apply
kubectl patch ft NAME --subresource=status --type=merge -p '{"status":{"state":"Booked"}}'

# catch a typo before it is pruned
kubectl apply -f x.yaml --validate=strict
kubectl apply -f x.yaml --dry-run=server

# who owns this object?
kubectl get cm NAME -o jsonpath='{.metadata.ownerReferences}{"\n"}'

# an object stuck in Terminating
kubectl get X NAME -o jsonpath='{.metadata.finalizers}{"\n"}'
kubectl patch X NAME --type=merge -p '{"metadata":{"finalizers":null}}'
```

**Traps**

- **`metadata.name` must be `<plural>.<group>`.** Exactly.
- **Exactly one version may have `storage: true`.**
- **A schema is mandatory** in `apiextensions.k8s.io/v1`.
- **Unknown fields are pruned silently.** `--validate=strict` catches it.
- **`kubectl apply` cannot write `status`** once the status subresource is
  enabled — use `--subresource=status`.
- **`flighttickets` and `flighttickets/status` are separate RBAC resources.**
- **`scope` cannot be changed** on an existing CRD; you delete and recreate,
  which destroys every object.
- **`kubectl delete crd` deletes every object of that kind, cluster-wide**, with
  no prompt.
- **Owner references only work within one namespace** (or from a cluster-scoped
  owner), and a dangling reference deletes the child immediately.
- **A finalizer stops deletion**, not the API call — the object sits in
  `Terminating` until the finalizer is removed.
- **A CRD with no controller does nothing.** It stores data. That is the whole
  answer to "I created the resource and nothing happened".
- An **operator** is a CRD plus a controller plus RBAC. Not a new API type.

---

**Previous:** [CKA 18 — Network Policies](../18-network-policies/)
**Next:** [CKA 20 — Storage Internals, Provisioners and CSI](../20-storage-internals-and-csi/)
