# CKA 20 solution

## Challenge answers

### C1 - Design the storage classes

```yaml
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: scratch
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
parameters: {type: gp3}
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: {name: database}
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  iops: "6000"
  encrypted: "true"
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: {name: archive}
provisioner: ebs.csi.aws.com
parameters: {type: sc1}
reclaimPolicy: Retain
volumeBindingMode: Immediate
allowVolumeExpansion: true
```

**`scratch`** — `Delete`, because the whole point is that it disappears with the
workload and nobody wants to reap orphaned volumes by hand.
`WaitForFirstConsumer`, because "must not constrain scheduling" is literally the
definition of that mode (20.6).

**`database`** — `Retain`, so a deleted namespace leaves a `Released` PV holding
the data rather than a deleted disk.  `WaitForFirstConsumer`, so the pod's
scheduling constraints (anti-affinity across zones, node taints) decide the zone
rather than the volume dictating it.

**`archive`** — `Immediate` is the one case where it is right: "capacity
guaranteed before the workload exists" is precisely a request to provision up
front and accept the scheduling constraint that follows. `Retain`, because
archives are the last copy of something.

**Default: `scratch`.** The default class is what a PVC gets when someone forgot
to think about storage, and a forgetful PVC should get the cheap, deletable,
non-constraining option. **Making `database` the default is the mistake** — every
absent-minded PVC in the cluster then creates an expensive volume that survives
deletion, and six months later nobody can say what any of them are for.

`allowVolumeExpansion: true` on all three is free: it costs nothing until used,
and retrofitting it is impossible without recreating the volume (20.5).

### C2 - Diagnose five Pending PVCs

**1. `waiting for first consumer to be created before binding`**

**Not a fault.** `volumeBindingMode: WaitForFirstConsumer` and no pod uses the
PVC yet.

```bash
kubectl get sc $(kubectl get pvc X -o jsonpath='{.spec.storageClassName}') \
  -o jsonpath='{.volumeBindingMode}{"\n"}'
kubectl get pods -o json | jq -r '.items[] | select(.spec.volumes[]?.persistentVolumeClaim.claimName=="X") | .metadata.name'
```

If the second command returns nothing, create a consumer. This is the one in the
list that is not a fault at all.

**2. `Pending`, no events, empty `storageClassName`**

**There is no default StorageClass**, so the admission controller had nothing to
inject and no provisioner claims the PVC. Silence is the signature.

```bash
kubectl get sc
kubectl get sc -o jsonpath='{range .items[*]}{.metadata.name}={.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}'
```

Note the distinction: `storageClassName: ""` (explicit empty string) means *"do
not use any class, bind only to a matching pre-created PV"* and is a different
thing from the field being absent.

**3. `storageclass "fast" not found`**

**A typo, or a class that was deleted.** Confirm and fix by recreating the class
— you cannot edit the PVC, since `storageClassName` is immutable, so the PVC has
to be recreated too.

```bash
kubectl get sc
kubectl get pvc X -o jsonpath='{.spec.storageClassName}{"\n"}'
```

**4. `rpc error ... InvalidVolumeSize`**

**The driver rejected the request** — everything on the Kubernetes side worked.
`rpc error` is the tell: that is a CSI `CreateVolume` call coming back with a
vendor error (20.3). Usually the size is below the driver's minimum (EBS `gp3`
will not do 100Mi) or not a permitted increment.

```bash
kubectl logs -n kube-system -l app=ebs-csi-controller -c csi-provisioner --tail=50
kubectl describe pvc X | tail -10
```

**5. `Bound`, pod stuck with `Multi-Attach error for volume`**

**The volume is `ReadWriteOnce` and is already attached to a different node**
(20.8). Almost always a rolling update where the old pod has not fully
terminated, or a node that went `NotReady` while holding the volume.

```bash
kubectl get pods -A -o wide -o json | jq -r '.items[] | select(.spec.volumes[]?.persistentVolumeClaim.claimName=="X") | "\(.metadata.name) \(.spec.nodeName) \(.status.phase)"'
kubectl get volumeattachments | grep <pv-name>
```

**`kubectl get volumeattachments` names the node still holding it.** If that node
is gone, the attachment has to be released — which is why a `NotReady` node with
attached volumes blocks workloads for six minutes before the timeout fires.

### C3 - Recover a Released PV

**1. Show the data exists without mounting it into a workload.**

Find the PV and where it lives, then look at it from the node:

```bash
kubectl get pv | grep Released
kubectl get pv <pv> -o jsonpath='{.spec.local.path}{" on "}{.spec.nodeAffinity}{"\n"}'
# ...or, for a cloud volume:
kubectl get pv <pv> -o jsonpath='{.spec.csi.volumeHandle}{"\n"}'
```

For a local-path volume, `docker exec <node> ls -l <path>`. For a cloud volume,
the `volumeHandle` is the disk ID you look up in the provider's console — the
volume is still there, detached.

**A read-only debug pod is the safe middle ground** if you must look at the
contents: mount the PV `readOnly: true` in a throwaway pod so nothing can write
to it while you are deciding.

**2. Bind a new PVC to it:**

```bash
# a. clear the stale binding
kubectl patch pv <pv> -p '{"spec":{"claimRef": null}}'
kubectl get pv <pv>          # now Available

# b. create a PVC that MATCHES it -- same class, same or smaller size,
#    same access modes
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: db-data-restored, namespace: prod}
spec:
  storageClassName: keep-my-data
  accessModes: ["ReadWriteOnce"]
  resources: {requests: {storage: 128Mi}}
  volumeName: <pv>            # bind to THIS pv, not just any matching one
EOF
```

**`volumeName` is the part people miss.** Without it the PVC may bind to some
other Available PV of the right size, and you have restored nothing.

**3. Why reusing the old name does not work.** The PV's `claimRef` records the
old claim's **UID**, not its name. A new PVC with an identical name gets a new
UID, so the reference does not match and the binding controller refuses. That is
deliberate — it stops a recreated PVC from silently inheriting a stranger's data.

**4. With `reclaimPolicy: Delete`,** the PV and the underlying disk would have
been deleted seconds after the PVC. There is no Kubernetes-side recovery: the
object is gone from etcd and `CreateVolume`'s counterpart `DeleteVolume` has
already run against the array.

**The only thing that saves them is a backup** — a volume snapshot, a
storage-array snapshot, or a database-level dump shipped off the cluster. Not
`Retain`, which merely delays the problem, and certainly not the PV object.
Storage that only exists in one place is not backed up, however good its reclaim
policy.

### C4 - The in-tree migration

**1. What it is.** An **in-tree volume plugin** — `awsElasticBlockStore` was a
volume type whose implementation lived inside the Kubernetes source tree (20.2).
The pod spec names an EBS volume ID directly and the kubelet, containing AWS
code, attached and mounted it.

**Why it no longer works:** in-tree cloud provider plugins have been removed.
`awsElasticBlockStore` was deprecated in 1.17 and **removed in 1.27** along with
the other in-tree cloud volume types. On a modern cluster the field either fails
validation or is accepted and never mounted, depending on version — both bad.

**2. What replaced it:** the **AWS EBS CSI driver** (`ebs.csi.aws.com`), which
must be **installed in the cluster** as the controller Deployment plus node
DaemonSet from 20.3, with an IAM role permitting the EC2 volume calls. It is not
present by default; on EKS it is an add-on you enable.

**3. CSI migration.** A transitional mechanism, on by default since 1.23 and
now the only path: **the in-tree API was silently redirected to the CSI driver.**
A pod or PV still saying `awsElasticBlockStore` had its operations translated
into CSI calls at runtime, so existing manifests kept working without being
rewritten — provided the CSI driver was installed.

That is what made the removal survivable. Clusters ran the CSI driver behind the
old field name for several releases, and only then was the field removed. **If
you meet a cluster that broke on upgrade to 1.27, the missing piece is almost
always that nobody installed the driver during the migration window.**

**4. The modern equivalent.** A pod should not name a disk at all — it names a
claim:

```yaml
---
apiVersion: v1
kind: PersistentVolume
metadata: {name: legacy-vol-0abc123}
spec:
  capacity: {storage: 100Gi}
  accessModes: ["ReadWriteOnce"]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""              # static: bind to this PV only
  csi:
    driver: ebs.csi.aws.com
    volumeHandle: vol-0abc123       # the same disk
    fsType: ext4
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: topology.ebs.csi.aws.com/zone
              operator: In
              values: ["eu-west-1a"]
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: legacy-data, namespace: prod}
spec:
  storageClassName: ""
  accessModes: ["ReadWriteOnce"]
  resources: {requests: {storage: 100Gi}}
  volumeName: legacy-vol-0abc123
```

```yaml
# ...and in the pod:
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: legacy-data
```

Two things the old form did not have and the new one needs:
**`nodeAffinity` naming the availability zone**, because an EBS volume exists in
one zone and the scheduler has to know; and the **PVC indirection**, which is
what lets the workload move between clusters without editing a disk ID into a
Deployment.

### C5 - Explain the layer model

**What happened.** `docker exec` (or `kubectl exec`) put a shell inside the
running container, and the edit was written to the container's **writable
layer** — the thin copy-on-write layer on top of the read-only image layers
(20.1). It worked, because from inside the container that layer is
indistinguishable from a real filesystem.

**What was destroyed: the container's writable layer**, and nothing else. The
image is untouched, the pod object is untouched, the node is untouched. When the
container was recreated, a **new empty writable layer** was stacked on the same
image, so the file reverted to whatever the image ships.

**Why "the pod restarted" is misleading.** The pod did not restart — pods do not
restart, they are created and deleted. **A container inside it was replaced**,
which is a much smaller and much more frequent event: a liveness probe failing,
an OOMKill, the process exiting non-zero. The pod kept its name, its IP, its
node, its volumes and its `creationTimestamp`; only `RESTARTS` moved. That is why
the developer saw no evidence of a restart and concluded something had been
"lost".

**Kubernetes did not lose the data.** It was never stored anywhere that
Kubernetes was asked to keep.

**The three legitimate ways to change that config file:**

| Approach | When |
|---|---|
| **Bake it into the image** and redeploy | it is part of the application and changes with releases |
| **A ConfigMap mounted as a volume** ([Day 09](../../../days/day-09-configmaps/)) | it is environment-specific configuration |
| **A PersistentVolume** | the application itself owns and rewrites the file at runtime |

**Use the ConfigMap.** It is the correct answer for nearly every "config file"
conversation: the content is versioned in Git, the change is auditable, it
applies to every replica rather than the one the developer happened to `exec`
into, and it survives every restart by construction.

The deeper lesson worth passing on: **anything you achieve with `exec` is
invisible to the cluster.** No other replica has it, no manifest records it, a
rollout removes it, and the next person cannot reproduce it. `exec` is a
debugging tool, not a deployment mechanism.

---

## Files

| File | Purpose |
|---|---|
| `01-pvc-default.yaml` | no class named -- the default is injected |
| `02-pod-uses-pvc.yaml` | the consumer that unblocks a WaitForFirstConsumer PVC |
| `03-storageclass-retain.yaml` | `Retain` + `allowVolumeExpansion` |
| `04-pvc-retain.yaml` | PVC and a writer, for the Released demonstration |
| `05-storageclass-immediate.yaml` | the same provisioner, `Immediate` binding |
| `06-pvc-immediate.yaml` | binds with no pod anywhere |
| `07-static-local-pv.yaml` | `no-provisioner` class, a `local` PV with nodeAffinity, and its PVC |
| `08-affinity-conflict-BAD.yaml` | pins a pod to the wrong node -- `volume node affinity conflict` |
| `09-rwo-two-nodes.yaml` | one RWO volume, two pods, anti-affinity |
| `verify.sh` | creates and removes its own probes; safe to re-run |

> **Do not `kubectl apply -f solution/`.** `08` is meant to fail and several
> files depend on steps having run in order.

---

## A note on what kind can and cannot show you

The lab uses kind's `local-path` provisioner throughout, which means two things
in this assignment are demonstrated by their **absence**:

- **`kubectl get csidrivers` is empty.** There is no CSI driver, because
  local-path is a plain controller (20.4). The sidecar architecture in 20.3 is
  described rather than run.
- **`kubectl get volumeattachments` is empty.** Nothing attaches a network disk
  to a node here; the "volume" is a directory that was already on the node.

Both absences are worth seeing — recognising that a cluster has *no* CSI driver
is a real diagnostic skill, and the reflex "check `volumeattachments`" is only
useful if you know what an empty result means.

What kind reproduces faithfully, and what actually matters for the exam:
`volumeBindingMode` and the node affinity it produces, reclaim policies and the
`Released` state, static versus dynamic provisioning, access-mode semantics, and
every failure message in Part 2. Those are identical on a cloud cluster.

If you want to see real CSI objects without a cloud account, install the
**`csi-driver-host-path`** test driver from the kubernetes-csi project — it
registers a genuine `CSIDriver`, runs the full sidecar set, and creates
`VolumeAttachment` objects, all against local directories. It is out of scope
here because it adds a dozen manifests to make one point.
