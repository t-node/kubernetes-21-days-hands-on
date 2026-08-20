# CKA 20 — Storage Internals, Provisioners and CSI

**Time:** 100-120 minutes
**Prerequisites:** [Day 14](../../days/day-14-volumes-pv-pvc/), [Day 15](../../days/day-15-statefulsets-and-headless-services/), [CKA 02](../02-container-runtimes-and-crictl/), [CKA 19](../19-crds-controllers-operators/)
**Source lectures:** 186, 187, 188, 189, 190, 191, 192, 193, 196, 199, 201

[Day 14](../../days/day-14-volumes-pv-pvc/) taught PVs, PVCs and access modes —
enough to give a database a disk. This assignment is the layer beneath: where
container data actually lives, what provisions a volume, and what CSI is for.

---

## Part 1 - Concepts

### 20.1 A container's filesystem is a stack of layers

An image is read-only layers. A running container adds **one writable layer** on
top, and the union of them is what the process sees:

```
   +-------------------------------+
   |  container writable layer     |   <- everything the process writes
   +-------------------------------+
   |  image layer N (COPY app)     |  \
   |  image layer 2 (RUN apk add)  |   |  read-only, SHARED between every
   |  image layer 1 (FROM alpine)  |  /   container from this image
   +-------------------------------+
```

**Copy-on-write:** modifying a file from a lower layer copies it up into the
writable layer first. The image is never changed, which is why a hundred
containers from one image cost one image on disk.

**The writable layer dies with the container.** Not with the pod — with the
*container*. A liveness probe restart wipes it while the pod keeps its name and
IP. That is the loss [Day 14](../../days/day-14-volumes-pv-pvc/) opened with, and
the layer model is why.

**Two different plugin systems get confused here:**

| | Manages | Example |
|---|---|---|
| **storage driver** | how layers are stacked and copied-on-write | `overlay2`, `btrfs`, `zfs` |
| **volume plugin** | persistent volumes attached to containers | `local`, and vendor drivers |

**A storage driver has nothing to do with persistence.** It is the union
filesystem for images. Volumes bypass it entirely — they are mounted into the
container from outside the layer stack, which is exactly why data on them
survives.

### 20.2 CSI, and why it exists

You have met this pattern twice already:

| Interface | Replaced | So that |
|---|---|---|
| **CRI** ([CKA 02](../02-container-runtimes-and-crictl/)) | runtime code inside Kubernetes | containerd and CRI-O work without patching Kubernetes |
| **CNI** ([CKA 18](../18-network-policies/)) | network code inside Kubernetes | Calico, Cilium, Flannel plug in |
| **CSI** | vendor storage code inside Kubernetes | EBS, Ceph, NetApp, Portworx plug in |

Before CSI, every storage vendor's driver lived **in the Kubernetes source tree**
("in-tree volume plugins"). A bug fix meant a Kubernetes release; a new vendor
meant convincing the Kubernetes maintainers. In-tree plugins are now removed, and
everything goes through CSI.

**CSI is not Kubernetes-specific.** It is a standard any orchestrator can
implement — which is the whole point of specifying it rather than defining an
API.

### 20.3 What a CSI driver actually is

The specification defines **RPCs** the orchestrator calls and the driver
implements, split across two services:

| Service | RPC | Called when |
|---|---|---|
| **Controller** | `CreateVolume` | a PVC needs a volume -- provision it on the array |
| | `DeleteVolume` | the PVC is gone and the policy says delete |
| | `ControllerPublishVolume` | attach the volume to a node |
| | `ControllerExpandVolume` | the PVC asked for more space |
| | `CreateSnapshot` | a VolumeSnapshot was created |
| **Node** | `NodeStageVolume` | format and mount it, once per node |
| | `NodePublishVolume` | bind-mount it into the pod's directory |
| | `NodeUnpublish` / `NodeUnstage` | the reverse, on teardown |

The driver runs **inside the cluster**, as ordinary Kubernetes workloads:

```
  CONTROLLER  (a Deployment, usually 1-2 replicas)
    +-- csi-provisioner   watches PVCs             -> CreateVolume
    +-- csi-attacher      watches VolumeAttachments -> ControllerPublishVolume
    +-- csi-resizer       watches PVC size changes  -> ControllerExpandVolume
    +-- csi-snapshotter   watches VolumeSnapshots   -> CreateSnapshot
    +-- THE VENDOR'S DRIVER CONTAINER

  NODE  (a DaemonSet, one per node)
    +-- node-driver-registrar  tells the kubelet this driver exists
    +-- THE VENDOR'S DRIVER CONTAINER   -> NodeStage / NodePublish
```

**The sidecars are generic and maintained by the Kubernetes project; only the
driver container is the vendor's.** Each sidecar is a controller in exactly the
sense of [CKA 19](../19-crds-controllers-operators/) — watch a resource, call an
API, write status.

Three API objects make it visible:

```bash
kubectl get csidrivers          # which drivers are registered
kubectl get csinodes            # which drivers each node can serve
kubectl get volumeattachments   # which volume is attached to which node, now
```

**`VolumeAttachment` is the one worth remembering.** It is a real, cluster-scoped
object recording an attachment, and it is what you read when a pod is stuck
waiting for a volume another node still holds.

### 20.4 A provisioner does not have to be CSI

kind's default StorageClass uses `rancher.io/local-path`, which is **not a CSI
driver at all** — it is a plain controller that watches PVCs and creates hostPath
PVs. No sidecars, no RPCs, no `CSIDriver` object.

```bash
kubectl get sc
kubectl get csidrivers               # empty on a stock kind cluster
kubectl get pods -n local-path-storage
```

That is legitimate: **the contract is "watch PVCs and produce bound PVs"**, and
CSI is one way to satisfy it, not the only one. Recognising the difference stops
you hunting for CSI objects that were never going to exist.

### 20.5 StorageClass, field by field

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: fast
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: rancher.io/local-path
parameters:                                 # vendor-specific, opaque to Kubernetes
  type: ssd
reclaimPolicy: Delete                       # or Retain
volumeBindingMode: WaitForFirstConsumer     # or Immediate
allowVolumeExpansion: true
mountOptions:
  - noatime
```

| Field | Matters because |
|---|---|
| **`provisioner`** | names the driver. **`kubernetes.io/no-provisioner` means no dynamic provisioning** — you create PVs by hand |
| **`parameters`** | passed straight to the driver; Kubernetes never validates them |
| **`reclaimPolicy`** | what happens to the PV when its PVC is deleted |
| **`volumeBindingMode`** | see 20.6 — the field people do not know they need |
| **`allowVolumeExpansion`** | without it, growing a PVC is rejected |
| **default-class annotation** | a PVC with no `storageClassName` gets this class, injected by an admission controller ([CKA 07](../07-admission-controllers/)) |

**Almost every field is immutable.** You cannot change a StorageClass's
`provisioner`, `parameters` or `reclaimPolicy` — you create a new class. Only the
default-class annotation and `allowVolumeExpansion` can be edited.

### 20.6 `volumeBindingMode` — the field that decides *when*

| Mode | The PV is provisioned |
|---|---|
| `Immediate` | as soon as the PVC is created |
| `WaitForFirstConsumer` | when a **pod using the PVC is scheduled** |

`Immediate` sounds better and is usually wrong. Consider a three-node cluster
with local disks or zonal cloud volumes:

```
  Immediate:                          WaitForFirstConsumer:
    PVC created                         PVC created -> Pending
    volume made on node-1               (nothing happens)
    pod created...                      pod created
    ...must go to node-1                scheduler picks node-2
    even if node-1 is full              volume made on node-2
```

**With `Immediate`, storage chooses the node and the scheduler must obey it.**
Every constraint from [Day 18](../../days/day-18-scheduling-taints-affinity-daemonsets/)
— affinity, taints, topology spread — becomes subordinate to a decision made
before the pod existed. The classic symptom:

```
0/3 nodes are available: 3 node(s) had volume node affinity conflict.
```

**`WaitForFirstConsumer` inverts it:** the scheduler decides, then the volume is
created where the pod landed. A PVC sitting `Pending` under
`WaitForFirstConsumer` **is not broken** — it is waiting for a consumer, exactly
as named.

### 20.7 PV lifecycle and reclaim policies

```
   Available --(a PVC binds)--> Bound --(PVC deleted)--> ?
                                                        |
              reclaimPolicy: Delete  -->  PV and the real storage removed
              reclaimPolicy: Retain  -->  PV becomes RELEASED and stays
```

**`Released` is not `Available`.** A released PV still records the UID of the PVC
that owned it, and **no new PVC will ever bind to it** — deliberately, because it
holds someone's data. To reuse it you clear `spec.claimRef`:

```bash
kubectl patch pv <name> -p '{"spec":{"claimRef": null}}'
```

The data is still there; that is the point of `Retain`. `Delete` is the right
default for a cache and a way to lose a database.

> **`Recycle` is deprecated and gone.** If you meet it in old material, the
> modern answers are `Delete` plus backups, or `Retain` plus a documented
> procedure.

### 20.8 Access modes, honestly

| Mode | Short | Means |
|---|---|---|
| `ReadWriteOnce` | RWO | one **node** may mount it read-write |
| `ReadOnlyMany` | ROX | many nodes, read-only |
| `ReadWriteMany` | RWX | many nodes, read-write |
| `ReadWriteOncePod` | RWOP | **one pod**, cluster-wide |

**RWO is per node, not per pod** — two pods on the *same* node can share an RWO
volume, which surprises people in both directions. `ReadWriteOncePod` is the mode
that actually means one pod, and it is what a database primary wants.

**The access mode is a request, not an enforcement**, except for RWOP.
Kubernetes matches a PVC to a PV claiming to support the mode; whether the
underlying storage can really do concurrent writes is the driver's problem. Most
block storage cannot do RWX at all, which is why RWX in practice means NFS or a
distributed filesystem.

---

## Part 2 - Hands-on lab

```bash
kubectl create namespace cka20
kubectl config set-context --current --namespace=cka20
```

### Step 1: Find the writable layer on the node

```bash
kubectl run scratch --image=busybox:1.36 --restart=Never -- sh -c 'sleep 3600'
kubectl wait --for=condition=Ready pod/scratch --timeout=60s
kubectl exec scratch -- sh -c 'echo "written at $(date +%T)" > /root/note.txt; cat /root/note.txt'
```

Now find that file **on the node**, outside Kubernetes entirely:

```bash
NODE=$(kubectl get pod scratch -o jsonpath='{.spec.nodeName}')
docker exec $NODE sh -c 'find /var/lib/containerd -name note.txt 2>/dev/null | head -3'
```

**That path is the container's upper (writable) layer** — the copy-on-write top
of the stack from 20.1. Now destroy the container without touching the pod:

```bash
CID=$(docker exec $NODE crictl ps --name scratch -q)
docker exec $NODE crictl stop $CID
sleep 20
kubectl get pod scratch
kubectl exec scratch -- cat /root/note.txt 2>&1 | tail -1
```

```
NAME      READY   STATUS    RESTARTS   AGE
scratch   1/1     Running   1          2m

cat: can't open '/root/note.txt': No such file or directory
```

**Same pod, same name, same IP — new writable layer, and the file is gone.** The
`RESTARTS` column is the only trace. This is the loss volumes exist to prevent,
and it happens on every OOMKill and every failed liveness probe.

```bash
docker exec $NODE crictl images | head -5
kubectl delete pod scratch --force --grace-period=0 2>/dev/null
```

Note the shared image layers: every busybox container on that node reads the same
read-only layers, and only the thin writable layer is per container.

### Step 2: Survey what this cluster can provision

```bash
kubectl get storageclass
kubectl get csidrivers
kubectl get csinodes
kubectl get volumeattachments
```

```
NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION
standard (default)   rancher.io/local-path   Delete          WaitForFirstConsumer   false
```

and **`No resources found`** for all three CSI queries.

**That is a finding, not a fault** (20.4). This cluster provisions with a plain
controller, not a CSI driver, so no `CSIDriver` was ever registered. On a cloud
cluster the same four commands would list the vendor's driver, one `CSINode` per
node, and a `VolumeAttachment` per attached disk.

### Step 3: The provisioner is a controller

```bash
kubectl get all -n local-path-storage
kubectl get configmap -n local-path-storage local-path-config -o jsonpath='{.data.config\.json}'; echo
```

```json
{"nodePathMap":[{"node":"DEFAULT_PATH_FOR_NON_LISTED_NODES","paths":["/opt/local-path-provisioner"]}]}
```

**That is where every PV on this cluster physically lives.** Watch it work:

```bash
kubectl apply -f solution/01-pvc-default.yaml
sleep 3
kubectl get pvc
```

```
NAME        STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   AGE
data-wffc   Pending                                      standard       3s
```

**`Pending`, and the provisioner logged nothing.** `standard` is
`WaitForFirstConsumer` (20.6) — no pod, no consumer, no volume.

```bash
kubectl describe pvc data-wffc | grep -A3 Events
```

```
Normal  WaitForFirstConsumer  waiting for first consumer to be created before binding
```

**Read the message: that is a status, not an error.** Now give it a consumer:

```bash
kubectl apply -f solution/02-pod-uses-pvc.yaml
sleep 15
kubectl get pvc,pv
kubectl logs -n local-path-storage -l app=local-path-provisioner --tail=10
```

The provisioner's log shows it creating a directory and then a PV. It is doing
exactly what your `FlightTicket` controller did in
[CKA 19](../19-crds-controllers-operators/): observe a resource, act, write the
result back.

```bash
NODE=$(kubectl get pod uses-pvc -o jsonpath='{.spec.nodeName}')
PV=$(kubectl get pvc data-wffc -o jsonpath='{.spec.volumeName}')
kubectl get pv $PV -o jsonpath='{.spec.nodeAffinity}{"\n"}'
docker exec $NODE ls -l /opt/local-path-provisioner/ 2>/dev/null || \
  docker exec $NODE ls -l /var/local-path-provisioner/
```

**The PV carries `nodeAffinity` pinning it to the node the pod was scheduled
on** — the scheduler chose, and the volume followed. That is
`WaitForFirstConsumer` visible in one field.

Prove the data really is on the node:

```bash
kubectl exec uses-pvc -- sh -c 'echo "persisted at $(date +%T)" > /data/proof.txt'
docker exec $NODE sh -c 'find /opt/local-path-provisioner /var/local-path-provisioner -name proof.txt 2>/dev/null | head -1 | xargs cat'
```

**The file is on the node's filesystem, outside every container layer.** Delete
the pod and it survives:

```bash
kubectl delete pod uses-pvc
kubectl apply -f solution/02-pod-uses-pvc.yaml
kubectl wait --for=condition=Ready pod/uses-pvc --timeout=60s
kubectl exec uses-pvc -- cat /data/proof.txt
```

### Step 4: `Retain`, and the `Released` state nobody expects

```bash
kubectl apply -f solution/03-storageclass-retain.yaml
kubectl apply -f solution/04-pvc-retain.yaml
kubectl wait --for=condition=Ready pod/retain-writer --timeout=90s
kubectl get pvc data-retain
PV=$(kubectl get pvc data-retain -o jsonpath='{.spec.volumeName}')
kubectl get pv $PV
```

Now delete the pod **and the claim**, as a careless cleanup would:

```bash
kubectl delete pod retain-writer
kubectl delete pvc data-retain
sleep 5
kubectl get pv $PV
```

```
NAME       CAPACITY   RECLAIM POLICY   STATUS     CLAIM                   STORAGECLASS
pvc-xxxx   128Mi      Retain           Released   cka20/data-retain       keep-my-data
```

**`Released`, not `Available`, and not deleted.** The data is intact — compare
with the default class, where the PV and the directory would both be gone.

Try to reuse it:

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: data-retain-2, namespace: cka20}
spec:
  storageClassName: keep-my-data
  accessModes: ["ReadWriteOnce"]
  resources: {requests: {storage: 128Mi}}
EOF
sleep 5
kubectl get pvc data-retain-2
kubectl get pv $PV -o jsonpath='{.spec.claimRef.uid}{"\n"}'
```

The new PVC does **not** bind to it. The PV still names the *old* claim's UID in
`spec.claimRef`, and a released PV is never recycled automatically (20.7). Clear
it by hand:

```bash
kubectl patch pv $PV -p '{"spec":{"claimRef": null}}'
sleep 5
kubectl get pv $PV
```

`Available`. **That is the manual step `Retain` buys you** — a deliberate
decision, taken by a human who has looked at the data, before anyone's volume is
reused.

```bash
kubectl delete pvc data-retain-2 --ignore-not-found
kubectl delete pv $PV --ignore-not-found
```

### Step 5: `Immediate` versus `WaitForFirstConsumer`

```bash
kubectl apply -f solution/05-storageclass-immediate.yaml
kubectl apply -f solution/06-pvc-immediate.yaml
sleep 8
kubectl get pvc
```

```
NAME             STATUS   VOLUME     CAPACITY   STORAGECLASS       AGE
data-immediate   Bound    pvc-yyyy   128Mi      bind-immediately   8s
data-wffc        Bound    pvc-xxxx   128Mi      standard           20m
```

**`data-immediate` bound with no pod anywhere.** A volume now exists, on a node
chosen by the provisioner:

```bash
PVI=$(kubectl get pvc data-immediate -o jsonpath='{.spec.volumeName}')
kubectl get pv $PVI -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms}{"\n"}'
```

That node was picked **before any scheduling decision existed**. Any pod using
this PVC must now go there, whatever else you would have preferred — the
inversion described in 20.6, in two commands.

```bash
kubectl delete pvc data-immediate
```

### Step 6: Static provisioning and a node affinity conflict

```bash
docker exec devops-worker mkdir -p /mnt/manual-disk
docker exec devops-worker sh -c 'echo "pre-existing data" > /mnt/manual-disk/hello.txt'

kubectl apply -f solution/07-static-local-pv.yaml
kubectl get pv local-pv-manual
kubectl get pvc local-pvc
```

`Pending` on both — `WaitForFirstConsumer` again. Now schedule a pod that
**cannot** work:

```bash
kubectl apply -f solution/08-affinity-conflict-BAD.yaml
sleep 15
kubectl get pod wrong-node
kubectl describe pod wrong-node | grep -A5 Events
```

```
0/3 nodes are available: 1 node(s) had volume node affinity conflict,
2 node(s) didn't match Pod's node affinity/selector.
```

**"volume node affinity conflict" means exactly one thing:** the volume is bound
to a node the pod cannot be placed on. Here you caused it with a `nodeSelector`;
in production it is usually a zonal disk and a pod that has to run elsewhere.

```bash
kubectl delete pod wrong-node
sed 's/devops-worker2/devops-worker/' solution/08-affinity-conflict-BAD.yaml | kubectl apply -f -
kubectl wait --for=condition=Ready pod/wrong-node --timeout=90s
kubectl exec wrong-node -- cat /data/hello.txt
```

```
pre-existing data
```

**The file was on the node before Kubernetes knew about it.** That is static
provisioning: the storage exists, and the PV is a description of it.

```bash
kubectl delete pod wrong-node
kubectl delete pvc local-pvc
kubectl delete pv local-pv-manual
```

### Step 7: RWO is per node

```bash
kubectl delete pod uses-pvc --ignore-not-found
kubectl apply -f solution/09-rwo-two-nodes.yaml
sleep 25
kubectl get pods -l app=rwo-test -o wide
kubectl describe pod rwo-second | grep -A5 Events
```

The second pod is stuck in `ContainerCreating` with a `FailedMount` or
`Multi-Attach` event, because `podAntiAffinity` forced it onto a different node
and the volume is `ReadWriteOnce` (20.8).

Now prove the "per node, not per pod" half:

```bash
kubectl delete pod rwo-second
sed 's/podAntiAffinity/podAffinity/' solution/09-rwo-two-nodes.yaml \
  | kubectl apply -f - 
sleep 20
kubectl get pods -l app=rwo-test -o wide
```

**Both Running, both mounting the same RWO volume, because they are on the same
node.** RWO never said "one pod" — `ReadWriteOncePod` is the mode that does.

```bash
kubectl exec rwo-first -- sh -c 'echo shared > /data/shared.txt'
kubectl exec rwo-second -- cat /data/shared.txt
```

### Step 8: Expansion

```bash
kubectl get sc standard -o jsonpath='{.allowVolumeExpansion}{"\n"}'      # empty/false
kubectl patch pvc data-wffc -p '{"spec":{"resources":{"requests":{"storage":"256Mi"}}}}'
```

```
persistentvolumeclaims "data-wffc" is forbidden: only dynamically provisioned
pvc can be resized and the storageclass that provisions the pvc must support resize
```

**A clear refusal**, and the fix is a class that permits it — `keep-my-data`
sets `allowVolumeExpansion: true`. Note you cannot retrofit it onto an existing
PVC: `storageClassName` is immutable, so the volume must be recreated.

```bash
kubectl get sc keep-my-data -o jsonpath='{.allowVolumeExpansion}{"\n"}'   # true
```

> **Expansion only ever grows.** Every driver rejects a shrink, and the API will
> too. Plan capacity accordingly.

### Cleanup

```bash
kubectl delete namespace cka20 --ignore-not-found
kubectl delete sc keep-my-data bind-immediately local-manual --ignore-not-found
kubectl delete pv local-pv-manual --ignore-not-found
docker exec devops-worker rm -rf /mnt/manual-disk
kubectl config set-context --current --namespace=default
```

---

## Part 3 - Challenges

### C1 - Design the storage classes

A platform team needs three classes on a cloud cluster with a CSI driver
(`ebs.csi.aws.com`):

- **`scratch`** — cheap, deleted with the workload, must not constrain scheduling
- **`database`** — SSD, survives the namespace being deleted by accident, growable
- **`archive`** — cheapest available, provisioned up front so capacity is
  guaranteed before the workload exists

Write all three. For each, justify `reclaimPolicy` and `volumeBindingMode` in one
sentence, and say which single class you would mark default and why.

### C2 - Diagnose five Pending PVCs

For each symptom give the most likely cause and the confirming command:

1. `Pending`, event: `waiting for first consumer to be created before binding`
2. `Pending`, no events at all, `storageClassName` is empty in the spec
3. `Pending`, event: `storageclass.storage.k8s.io "fast" not found`
4. `Pending`, class exists, provisioner pod is `Running`, event:
   `failed to provision volume with StorageClass "fast": rpc error ... InvalidVolumeSize`
5. `Bound`, but the pod using it is stuck in `ContainerCreating` with
   `Multi-Attach error for volume`

Which of these is not a fault at all?

### C3 - Recover a Released PV

A colleague deleted a PVC for a production database. The class used
`reclaimPolicy: Retain`, so the PV is `Released`.

1. Show the data still exists, without mounting it into a workload.
2. Give the exact steps to bind a **new** PVC to that same PV, with the data
   intact.
3. Explain why creating a PVC with the same name as the old one does not work.
4. What would have happened with `reclaimPolicy: Delete`, and what is the only
   thing that would have saved them?

### C4 - The in-tree migration

An old manifest contains:

```yaml
  awsElasticBlockStore:
    volumeID: vol-0abc123
    fsType: ext4
```

1. What is this, and why does it no longer work on a modern cluster?
2. What replaced it, and what has to be installed for the replacement to work?
3. What is "CSI migration" and what did it do for clusters that had manifests
   like this?
4. Write the modern equivalent.

### C5 - Explain the layer model

A developer says: "I `docker exec`'d into the container and edited the config
file, and it worked. Then the pod restarted and my change was gone. Kubernetes
lost my data."

Give the explanation in terms of 20.1, name the exact thing that was destroyed,
and say why "the pod restarted" is a misleading description of what happened.
Then give the three legitimate ways to change that config file and say which one
you would use.

---

## Part 4 - Verify

```bash
bash solution/verify.sh
```

Checks: the default class is `WaitForFirstConsumer`; a PVC with no consumer
stays Pending and binds once a pod exists; the resulting PV carries node
affinity matching the pod's node; a `Retain` class leaves a `Released` PV
holding its `claimRef`; an `Immediate` class binds with no pod; the static local
PV produces a node affinity conflict against the wrong node; and expansion is
refused by a class that does not allow it.

---

## Part 5 - Exam notes

**Fast paths**

```bash
# the survey, in four commands
kubectl get sc
kubectl get pv
kubectl get pvc -A
kubectl get csidrivers,csinodes,volumeattachments

# which class is default?
kubectl get sc -o custom-columns=NAME:.metadata.name,\
DEFAULT:.metadata.annotations."storageclass\.kubernetes\.io/is-default-class",\
MODE:.volumeBindingMode,RECLAIM:.reclaimPolicy,EXPAND:.allowVolumeExpansion

# change the default class (unset the old one FIRST)
kubectl patch sc old -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
kubectl patch sc new -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# why is this PVC Pending?
kubectl describe pvc NAME | tail -12

# which PV, on which node, holding what?
kubectl get pvc NAME -o jsonpath='{.spec.volumeName}{"\n"}'
kubectl get pv NAME -o jsonpath='{.spec.nodeAffinity}{"\n"}'

# reuse a Released PV
kubectl patch pv NAME -p '{"spec":{"claimRef": null}}'

# grow a PVC (the class must allow it)
kubectl patch pvc NAME -p '{"spec":{"resources":{"requests":{"storage":"20Gi"}}}}'
```

**Traps**

- **The container writable layer dies with the container**, not the pod. A
  restart is enough.
- **Storage drivers (`overlay2`) are not volume plugins.** One stacks image
  layers; the other persists data.
- **A `Pending` PVC under `WaitForFirstConsumer` is normal.** Read the event
  before treating it as a fault.
- **`Immediate` lets storage pick the node**, and produces
  `volume node affinity conflict` later.
- **`Released` is not `Available`.** Clear `spec.claimRef` to reuse a `Retain`ed
  PV.
- **Almost every StorageClass field is immutable** — create a new class instead.
- **`storageClassName` on a PVC is immutable too.**
- **`allowVolumeExpansion` must be on the class before the PVC is created.**
  Expansion grows only; shrinking is always refused.
- **RWO is per node.** Two pods on one node can share it; `ReadWriteOncePod` is
  the per-pod mode.
- **`kubernetes.io/no-provisioner` means static only** — nothing will provision
  for that class.
- **A `local` PV requires `nodeAffinity`.** Without it the scheduler will place
  pods where the data is not.
- **Two default classes is a misconfiguration**; PVCs then get neither
  reliably. Unset the old one before setting the new.
- **A CSI driver is workloads plus objects** — `csidrivers`, `csinodes`,
  `volumeattachments`. Their absence can be correct (kind), and on a cloud
  cluster it is a fault.

---

**Previous:** [CKA 19 — Custom Resources, Controllers and Operators](../19-crds-controllers-operators/)
**Next: CKA 21 — Linux Networking Foundations** *(not yet built — see [CURRICULUM.md](../CURRICULUM.md))*
