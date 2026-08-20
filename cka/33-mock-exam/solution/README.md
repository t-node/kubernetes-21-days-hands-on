# CKA 33 solution — the answer key

> **Grade yourself with `bash solution/grade.sh` before reading this.** The
> grader checks end state, so a different command producing the same result is
> equally correct — and several of these have more than one good answer.

---

## Cluster Architecture, Installation & Configuration

### Task 1 — ServiceAccount limited to pods and logs (4 pts)

```bash
kubectl -n mock-a create serviceaccount pipeline
kubectl -n mock-a create role pod-reader \
  --verb=get,list,watch --resource=pods,pods/log
kubectl -n mock-a create rolebinding pipeline-reads \
  --role=pod-reader --serviceaccount=mock-a:pipeline
```

**Verify — the habit, not an extra:**

```bash
kubectl auth can-i list pods    --as=system:serviceaccount:mock-a:pipeline -n mock-a   # yes
kubectl auth can-i get pods/log --as=system:serviceaccount:mock-a:pipeline -n mock-a   # yes
kubectl auth can-i delete pods  --as=system:serviceaccount:mock-a:pipeline -n mock-a   # no
```

**`pods/log` is a separate resource from `pods`** — a Role granting only `pods`
cannot read logs, and that is the half of this task people miss
([Day 19](../../../days/day-19-rbac/)).

### Task 2 — read-only auditor (4 pts)

```bash
kubectl -n mock-a create role read-all --verb=get,list,watch --resource='*'
kubectl -n mock-a create rolebinding auditor-reads --role=read-all --user=auditor
```

**`--resource='*'` is the shortcut**, and the wildcard covers resources created
later too. It is a **Role**, not a ClusterRole, so it stops at the namespace
boundary — which is what the task asked for.

### Task 3 — etcd snapshot (5 pts)

```bash
docker exec devops-control-plane etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /opt/etcd-backup.db

docker exec devops-control-plane etcdutl snapshot status /opt/etcd-backup.db --write-out=table
```

**The three certificate flags are the whole task**, and they are the thing to
have memorised ([CKA 03](../../03-etcd-and-cluster-data/),
[CKA 12](../../12-cluster-maintenance/)).

**`snapshot status` moved to `etcdutl`**; `etcdctl snapshot status` still works
with a deprecation warning. Either is accepted.

**Read where the task says to put the file.** "On the control-plane node" and
"inside the etcd pod" are different filesystems, and the exam means the node.

### Task 4 — certificate expiry (4 pts)

```bash
docker exec devops-control-plane sh -c '
  A=$(openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -enddate | cut -d= -f2)
  C=$(openssl x509 -in /etc/kubernetes/pki/ca.crt        -noout -enddate | cut -d= -f2)
  printf "apiserver: %s\nca: %s\n" "$A" "$C" > /opt/cert-expiry.txt
  cat /opt/cert-expiry.txt'
```

The faster route to the same information:

```bash
docker exec devops-control-plane kubeadm certs check-expiration
```

**`kubeadm certs check-expiration` covers the leaves, the kubeconfigs and the CAs
in one table** ([CKA 13](../../13-tls-in-kubernetes/)). Use it to find the
answer; use `openssl` when the task wants a specific format.

### Task 5 — StorageClass (4 pts)

```bash
kubectl get sc                       # find the default's provisioner first

kubectl apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: mock-retain
provisioner: rancher.io/local-path      # whatever the default uses
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOF
```

**There is no `kubectl create storageclass`** — this one must be YAML. Copy the
default as a starting point:

```bash
kubectl get sc standard -o yaml > sc.yaml    # then edit name, reclaimPolicy, expansion
```

**Almost every StorageClass field is immutable**
([CKA 20](../../20-storage-internals-and-csi/)), which is why the task says
"create" rather than "modify the default".

### Task 6 — static pod (4 pts)

```bash
kubectl run mock-static --image=nginx:1.27-alpine --dry-run=client -o yaml > /tmp/ms.yaml
docker cp /tmp/ms.yaml devops-worker:/etc/kubernetes/manifests/mock-static.yaml
kubectl get pods -A | grep mock-static
```

```
default   mock-static-devops-worker   1/1   Running
```

**The `-devops-worker` suffix is how you know it is a static pod**
([CKA 05](../../05-manual-scheduling-and-static-pods/)) — the kubelet appends the
node name to the mirror pod.

**Never assume the directory is `/etc/kubernetes/manifests`:**

```bash
docker exec devops-worker grep staticPodPath /var/lib/kubelet/config.yaml
```

**Delete it by removing the file**, not with `kubectl delete pod` — the kubelet
recreates it immediately.

---

## Workloads & Scheduling

### Task 7 — a Deployment with resources (3 pts)

```bash
kubectl -n mock-w create deploy frontend --image=nginx:1.27-alpine --replicas=3
kubectl -n mock-w set resources deploy frontend --requests=cpu=50m --limits=memory=128Mi
kubectl -n mock-w patch deploy frontend --type=json -p \
  '[{"op":"add","path":"/spec/template/spec/containers/0/ports","value":[{"name":"http","containerPort":80}]}]'
```

**`kubectl set resources` is the fast path** and saves opening an editor. The
alternative is `--dry-run=client -o yaml`, edit, apply — equally correct.

### Task 8 — two containers, one volume (3 pts)

```bash
kubectl -n mock-w apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: multi}
spec:
  volumes:
    - name: shared
      emptyDir: {}
  containers:
    - name: main
      image: nginx:1.27-alpine
      volumeMounts: [{name: shared, mountPath: /shared}]
    - name: sidecar
      image: busybox:1.36
      command: ["sh", "-c", "sleep 3600"]
      volumeMounts: [{name: shared, mountPath: /shared}]
EOF
```

**Both containers need their own `volumeMounts`** — declaring the volume once at
pod level does not mount it anywhere
([CKA 10](../../10-multi-container-and-init/)).

### Task 9 — a CronJob with history limits (3 pts)

```bash
kubectl -n mock-w create cronjob reporter --image=busybox:1.36 \
  --schedule="*/5 * * * *" --dry-run=client -o yaml \
  -- sh -c 'date; echo report' > cj.yaml
```

Add the two limits under `spec:` and apply:

```yaml
spec:
  schedule: "*/5 * * * *"
  successfulJobsHistoryLimit: 2
  failedJobsHistoryLimit: 1
```

**The `--` before the command is required**, and everything after it is the
container's command rather than a `kubectl` flag.

### Task 10 — label and pin (3 pts)

```bash
kubectl label node devops-worker2 tier=gold
kubectl -n mock-w run picky --image=nginx:1.27-alpine \
  --overrides='{"spec":{"nodeSelector":{"tier":"gold"}}}'
kubectl -n mock-w get pod picky -o wide
```

**`nodeSelector` is the short answer; `nodeAffinity` is the long one.** Both
score; use whichever you can type without a mistake
([Day 18](../../../days/day-18-scheduling-taints-affinity-daemonsets/)).

### Task 11 — scale and record (3 pts)

```bash
kubectl -n mock-w scale deploy frontend --replicas=5
kubectl -n mock-w annotate deploy frontend \
  kubernetes.io/change-cause="scaled to 5 for the mock exam" --overwrite
kubectl -n mock-w rollout history deploy frontend
```

**`--record` is deprecated and removed.** The replacement is setting the
`kubernetes.io/change-cause` annotation by hand — which is exactly what
`rollout history` reads
([Day 05](../../../days/day-05-rolling-updates-and-rollbacks/)).

---

## Services & Networking

### Task 12 — ClusterIP to a named port (4 pts)

```bash
kubectl -n mock-n expose deploy web --name=web-svc --port=80 --target-port=http
kubectl -n mock-n get endpoints web-svc
```

**`--target-port` accepts a port *name*** as well as a number, and naming it is
better: the Service keeps working if the container's port number changes
([CKA 23](../../23-service-networking/)).

**Always check `get endpoints` after creating a Service.** An empty result means
the selector is wrong, and it is the difference between a task that scores and
one that does not.

### Task 13 — NodePort preserving the client IP (4 pts)

```bash
kubectl -n mock-n expose deploy web --name=web-np --type=NodePort \
  --port=80 --target-port=http --dry-run=client -o yaml > np.yaml
```

Then add two fields and apply:

```yaml
spec:
  type: NodePort
  externalTrafficPolicy: Local
  ports:
    - port: 80
      targetPort: http
      nodePort: 30333
```

Or patch after creating:

```bash
kubectl -n mock-n patch svc web-np -p \
  '{"spec":{"externalTrafficPolicy":"Local","ports":[{"port":80,"targetPort":"http","nodePort":30333}]}}'
```

**"Preserves the client's source IP" means `externalTrafficPolicy: Local`**
([CKA 23](../../23-service-networking/), 23.7). The default, `Cluster`, SNATs
traffic forwarded between nodes and loses the client address.

### Task 14 — headless Service (4 pts)

```bash
kubectl -n mock-n expose deploy web --name=web-hl --port=80 --target-port=http \
  --cluster-ip=None
```

Proving it returns N addresses:

```bash
kubectl -n mock-n run t --rm -it --restart=Never --image=busybox:1.36 -- \
  nslookup web-hl.mock-n.svc.cluster.local
```

**A headless Service returns one A record per ready endpoint** rather than a
single ClusterIP ([CKA 24](../../24-dns-and-coredns/)) — and has no iptables
rules at all.

**Watch out for `kubectl create svc clusterip`** — it sets a selector of
`app: <service-name>`, which will not match your Deployment. `expose` derives the
selector from the workload, which is why it is the safer verb.

### Task 15 — default-deny ingress (4 pts)

```bash
kubectl -n mock-n apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all-ingress
spec:
  podSelector: {}
  policyTypes:
    - Ingress
EOF
```

**Three lines of `spec` and no rules at all.** `podSelector: {}` selects every
pod in the namespace; `policyTypes: [Ingress]` isolates them for that direction;
the absence of an `ingress:` list means nothing is allowed back in
([CKA 18](../../18-network-policies/), 18.3).

**Note this policy does nothing on the repo's kind cluster** — kindnet does not
implement NetworkPolicy. The object is still correct and the grader checks the
object. **In the exam the cluster enforces it.**

### Task 16 — the DNS facts (4 pts)

```bash
{
  kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}{"\n"}'
  kubectl -n kube-system get pods -l k8s-app=kube-dns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
} > /tmp/mock-dns.txt
cat /tmp/mock-dns.txt
```

**The label is `k8s-app=kube-dns`, not `app=coredns`** — the Deployment is called
`coredns` and the label is the historical one
([CKA 24](../../24-dns-and-coredns/), 24.2). Getting it wrong returns an empty
list, silently.

---

## Storage

### Task 17 — PVC, pod, and proving persistence (10 pts)

```bash
kubectl -n mock-s apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: data}
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 200Mi
---
apiVersion: v1
kind: Pod
metadata: {name: writer}
spec:
  containers:
    - name: w
      image: busybox:1.36
      command: ["sh", "-c", "echo mock-exam-ok > /data/proof.txt; sleep 36000"]
      volumeMounts: [{name: d, mountPath: /data}]
  volumes:
    - name: d
      persistentVolumeClaim: {claimName: data}
EOF
```

**Omitting `storageClassName` gets the cluster default**, injected by an
admission controller ([CKA 20](../../20-storage-internals-and-csi/), 20.5).
Naming it explicitly is also fine.

Proving persistence, which is what earns the points:

```bash
kubectl -n mock-s exec writer -- cat /data/proof.txt      # mock-exam-ok
kubectl -n mock-s delete pod writer
kubectl -n mock-s apply -f -   # ...the same pod manifest again
kubectl -n mock-s exec writer -- cat /data/proof.txt      # still mock-exam-ok
```

**Note the PVC stays `Pending` until a pod uses it** on this cluster —
`WaitForFirstConsumer` (20.6). That is not a fault, and it is worth recognising
so you do not "fix" it.

---

## Troubleshooting

### Task 18 — mock-t1 (6 pts)

**The fault:** the Service's selector is `app: web-server`; the pods are
`app: web`.

```bash
kubectl -n mock-t1 get endpoints web              # <none>   <- the diagnosis
kubectl -n mock-t1 get svc web -o jsonpath='{.spec.selector}{"\n"}'
kubectl -n mock-t1 get pods --show-labels

kubectl -n mock-t1 patch svc web -p '{"spec":{"selector":{"app":"web"}}}'
kubectl -n mock-t1 exec client -- curl -s -o /dev/null -w "%{http_code}\n" http://web
```

**`get endpoints` first, always** ([CKA 31](../../31-troubleshooting/), 31.3). An
empty result has exactly three causes and this is the most common.

### Task 19 — mock-t2 (6 pts)

**The fault:** the readiness probe targets port 8080; nginx listens on 80.

```bash
kubectl -n mock-t2 get pods                       # 0/1 Running -- not a crash
kubectl -n mock-t2 describe pod <one> | grep -A5 Events
```

```
Warning  Unhealthy  Readiness probe failed: dial tcp 10.244.x.x:8080: connect: connection refused
```

```bash
kubectl -n mock-t2 patch deploy api --type=json -p \
  '[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/port","value":80}]'
kubectl -n mock-t2 rollout status deploy/api
```

**`Running` at `0/1` is a readiness problem, not a crash** (31.7). The container
is fine; the probe's answer is what is wrong.

### Task 20 — mock-t3 (6 pts)

**The fault:** the pod references `CACHE_SIZE_MB` in a ConfigMap that only has
`MAX_ENTRIES`.

```bash
kubectl -n mock-t3 get pod cache                  # CreateContainerConfigError
kubectl -n mock-t3 describe pod cache | tail -10
```

```
Error: couldn't find key CACHE_SIZE_MB in ConfigMap mock-t3/cache-config
```

Two valid fixes — **either** add the key:

```bash
kubectl -n mock-t3 patch cm cache-config -p '{"data":{"CACHE_SIZE_MB":"256"}}'
kubectl -n mock-t3 delete pod cache      # a bare pod will not re-read it
```

**or** point the pod at the key that exists. **`CreateContainerConfigError` means
the kubelet rejected the configuration** — a missing ConfigMap key, a missing
Secret, or `runAsNonRoot` on a root image
([CKA 17](../../17-image-security-and-security-contexts/)).

### Task 21 — mock-t4 (6 pts)

**The fault is in the cluster, not the workload** — the task says so.

The Deployment tolerates `workload=batch:NoSchedule` and requires nodes labelled
`workload-class=batch`. **No node has that label**, and `devops-worker2` carries
an unrelated `mock-t4=blocked:NoSchedule` taint.

```bash
kubectl -n mock-t4 describe pod <pending> | grep -A5 Events
```

```
0/3 nodes are available: 1 node(s) had untolerated taint {mock-t4: blocked},
2 node(s) didn't match Pod's node affinity/selector.
```

**Read both halves of that message.** Then make the cluster match what the
workload asks for:

```bash
kubectl label node devops-worker workload-class=batch
kubectl taint node devops-worker workload=batch:NoSchedule
kubectl taint node devops-worker2 mock-t4-
kubectl -n mock-t4 rollout status deploy/worker
```

**The instruction not to touch the workload is the whole lesson.** The reflex is
to delete the affinity rule and make the symptom go away — which would put a
batch workload onto general-purpose nodes and be exactly wrong. **When a pod
cannot schedule, ask whether the pod is wrong or the cluster is.**

### Task 22 — mock-t5 (3 pts)

```bash
kubectl -n mock-t5 create role pod-lister --verb=get,list,watch --resource=pods
kubectl -n mock-t5 create rolebinding reader-lists \
  --role=pod-lister --serviceaccount=mock-t5:reader

kubectl auth can-i list pods --as=system:serviceaccount:mock-t5:reader -n mock-t5
```

**"Exactly that, without changing anything else" rules out
`--clusterrole=view`** — which would also grant Services, ConfigMaps and
Deployments. The grader checks that `delete pods` is still denied.

### Task 23 — unschedulable nodes (3 pts)

```bash
kubectl get nodes -o jsonpath='{range .items[?(@.spec.unschedulable==true)]}{.metadata.name}{"\n"}{end}' \
  > /tmp/mock-unschedulable.txt
cat /tmp/mock-unschedulable.txt
```

**If no node is cordoned the file is empty, and that is the correct answer** —
the task says it must exist. Redirection creates it either way, which is why this
form is right.

The `custom-columns` alternative needs `--no-headers`, or the header itself
counts as a line:

```bash
kubectl get nodes --field-selector spec.unschedulable=true \
  -o custom-columns=NAME:.metadata.name --no-headers > /tmp/mock-unschedulable.txt
```

---

## After the exam

### Reading your score

**A pass here is not a pass there.** These tasks are friendlier than the real
exam's in three specific ways:

- **You know which namespace each task is in.** The exam gives you a context to
  switch to and penalises you for forgetting.
- **The troubleshooting scenarios are single-fault.** Real exam tasks sometimes
  have two.
- **Nothing here is deliberately time-consuming.** The exam includes at least one
  task designed to eat twenty minutes if you let it.

**What the per-domain score tells you:**

| Result | What to do |
|---|---|
| Troubleshooting below 20/30 | redo [CKA 31](../../31-troubleshooting/) with `break.sh random` |
| Architecture below 17/25 | [CKA 12](../../12-cluster-maintenance/), [CKA 13](../../13-tls-in-kubernetes/), [CKA 15](../../15-certificates-api-and-authorization/) |
| Networking below 14/20 | [CKA 23](../../23-service-networking/), [CKA 24](../../24-dns-and-coredns/) |
| Workloads below 10/15 | [Day 04](../../../days/day-04-labels-replicasets-deployments/), [Day 18](../../../days/day-18-scheduling-taints-affinity-daemonsets/) |
| Storage below 7/10 | [Day 14](../../../days/day-14-volumes-pv-pvc/), [CKA 20](../../20-storage-internals-and-csi/) |

**And the more useful number: how many tasks did you finish?** Running out of
time is the most common way people fail, and the fix is not more knowledge — it
is the habits in 33.3.

### Re-running it

```bash
bash solution/setup-mock.sh clean
bash solution/setup-mock.sh
```

**The broken namespaces are recreated identically**, so a second attempt tests
whether you remember the *method* rather than the answers. Leave a week between
attempts.

---

## Files

| File | Purpose |
|---|---|
| `setup-mock.sh` | creates the namespaces and the five broken scenarios; `clean` removes everything |
| `grade.sh` | checks the end state of all 23 graded tasks and scores by domain |

---

## On the grader

**It checks end state, exactly as the real exam does.** That has two
consequences worth understanding:

**A different command scores the same.** Task 13 can be a YAML file, an
`expose --dry-run` plus an edit, or a `patch` — the grader looks at the Service,
not at how it got there. **Use whichever you can type correctly.**

**A task that "looks right" can score zero.** The most common causes here are the
same as in the exam:

- the object is in the **wrong namespace**
- a field is a **string where a number was wanted**, or the reverse
- the Service has **no endpoints** because the selector does not match
- the pod is `Running` but not `Ready`

**Which is why the ten seconds of verification per task in 33.3 is the
best-value time you will spend.** `kubectl get` and `kubectl describe | tail`
catch all four.

### Task 21's special check

The grader for task 21 checks **both** that three replicas are ready **and** that
the workload's tolerations and affinity are unchanged. If you removed them to
make the pods schedule, it prints:

```
         (3 replicas ready, but the workload's tolerations/affinity were changed)
```

and awards zero. **That is deliberate**, and it is the only task in the bank
where a working cluster scores nothing — because "make the symptom go away" and
"fix the problem" are different, and the exam sometimes tests the difference.
