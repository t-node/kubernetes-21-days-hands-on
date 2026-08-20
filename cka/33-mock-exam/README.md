# CKA 33 — Mock Exam Task Bank

**Time:** 120 minutes, timed
**Prerequisites:** everything. This is the last assignment on the track.
**Source lectures:** 299, 300, 301, 302, 304, 306

Twenty-four tasks, weighted to match the real exam's domains, on the cluster you
have been building all along. **Set a timer, do not open another assignment, and
grade yourself at the end.**

---

## Part 1 - How the exam works

### 33.1 The format

| | |
|---|---|
| **Duration** | 2 hours |
| **Tasks** | roughly 15-20, each worth a different number of points |
| **Passing** | 66% |
| **Environment** | a browser terminal, several clusters, `kubectl` preinstalled |
| **Documentation** | **kubernetes.io/docs and its subdomains are allowed**, in one extra tab |
| **Retake** | one free retake with the standard purchase |

**It is performance-based.** There are no multiple-choice questions — every task
asks you to change a cluster and is graded on the end state.

### 33.2 The domains, and how they are weighted

| Domain | Weight | In this bank |
|---|---|---|
| **Troubleshooting** | **30%** | tasks 18-24 |
| **Cluster Architecture, Installation & Configuration** | **25%** | tasks 1-6 |
| **Services & Networking** | **20%** | tasks 12-16 |
| **Workloads & Scheduling** | **15%** | tasks 7-11 |
| **Storage** | **10%** | tasks 17, and part of 5 |

**Troubleshooting is the largest single domain**, and it is the one people
prepare for least. [CKA 31](../31-troubleshooting/) is the assignment that
matters most for the exam.

### 33.3 The five habits that are worth points

**1. Read the context line. Every task.**

```bash
kubectl config use-context <the-one-the-task-named>
```

**Every task begins by telling you which cluster to work on.** Doing perfect work
on the wrong cluster scores zero, and it is the single most common way people
lose marks.

**2. Set up your shell in the first sixty seconds.**

```bash
alias k=kubectl
export do="--dry-run=client -o yaml"
export now="--force --grace-period=0"
source <(kubectl completion bash)
```

Then `k run x --image=nginx $do > x.yaml` is a manifest skeleton in one line.

**3. Generate; do not type YAML from memory.**

```bash
kubectl create deploy web --image=nginx --replicas=3 $do > web.yaml
kubectl create svc clusterip web --tcp=80:8080 $do > svc.yaml
kubectl create job j --image=busybox $do -- sh -c 'echo hi' > job.yaml
kubectl create cronjob c --image=busybox --schedule="*/1 * * * *" $do -- date > cj.yaml
```

**Nobody writes a Deployment by hand under time pressure.** Generate the
skeleton, edit the two fields that matter, apply.

**4. Skip and come back.**

A task you cannot start in ninety seconds is a task to flag and leave. **Points
are not proportional to difficulty**, and a five-point task you skipped is worth
more than a twelve-point one you half-finished.

**5. Verify before moving on.**

```bash
kubectl get <what-you-made>
kubectl describe <what-you-made> | tail -20
```

**Ten seconds of verification per task is the best-value time in the exam.** A
typo you did not check costs the whole task.

### 33.4 Using the documentation well

You have one extra tab on `kubernetes.io/docs`. **Practise finding things there
now, not in the exam.**

The pages worth knowing the shape of:

| Need | Search for |
|---|---|
| a pod spec field | **`kubectl explain pod.spec.<field>`** -- faster than the browser |
| any YAML skeleton | the concept page's examples section |
| `kubeadm` upgrade steps | "Upgrading kubeadm clusters" |
| a NetworkPolicy example | "Network Policies" -- the page has copyable examples |
| RBAC verbs | "Using RBAC Authorization" |
| a StorageClass field | "Storage Classes" |

**`kubectl explain --recursive` beats the browser for field names**, every time.
The browser is for procedures and complete examples.

### 33.5 Scoring this bank

Each task below carries points. **The total is 100 and the pass mark is 66** —
the same as the real exam.

```bash
bash solution/grade.sh
```

It checks the end state of every task and prints a score by domain, so you find
out which domain to go back to rather than just whether you passed.

---

## Part 2 - Setup

**Do this before starting the timer.**

```bash
kubectl config use-context kind-devops
bash solution/setup-mock.sh
```

It creates the namespaces and the broken objects the troubleshooting tasks need,
and prints nothing about what is wrong with them.

**Then set your timer for two hours and begin.**

---

## Part 3 - The tasks

> Every task says which namespace to work in. **There is no context to switch on
> a single-cluster lab — but read the namespace line every time anyway, because
> that is the habit the exam rewards.**

### Cluster Architecture, Installation & Configuration — 25 points

**Task 1 — 4 points.** *Namespace: `mock-a`.*
Create a ServiceAccount `pipeline` and grant it permission to `get`, `list` and
`watch` **pods and pods/log** in that namespace, and nothing else. Do not use
`cluster-admin` or any built-in ClusterRole.

**Task 2 — 4 points.** *Namespace: `mock-a`.*
Create a Role and RoleBinding so that the user `auditor` can `get` and `list`
**every** resource in `mock-a` but cannot modify anything. Verify with
`kubectl auth can-i`.

**Task 3 — 5 points.** *Cluster-wide.*
Take an etcd snapshot to `/opt/etcd-backup.db` on the control-plane node. Then
print the snapshot's status showing its revision and size.

**Task 4 — 4 points.** *Cluster-wide.*
Print the expiry date of the API server certificate and of the cluster CA, and
write both to `/opt/cert-expiry.txt` on the control-plane node in the form
`apiserver: <date>` and `ca: <date>`.

**Task 5 — 4 points.** *Namespace: `mock-a`.*
A StorageClass named `mock-retain` must exist that uses the same provisioner as
the cluster default, keeps its volumes when the PVC is deleted, and allows
volume expansion.

**Task 6 — 4 points.** *Cluster-wide.*
Create a static pod named `mock-static` on **`devops-worker`** that runs
`nginx:1.27-alpine`. It must survive a kubelet restart and must not be managed
by any controller.

### Workloads & Scheduling — 15 points

**Task 7 — 3 points.** *Namespace: `mock-w`.*
Create a Deployment `frontend` with 3 replicas of `nginx:1.27-alpine`, exposing
container port 80 under the name `http`, with a CPU request of `50m` and a
memory limit of `128Mi`.

**Task 8 — 3 points.** *Namespace: `mock-w`.*
Create a pod `multi` with two containers: `main` running `nginx:1.27-alpine`,
and `sidecar` running `busybox:1.36` executing `sleep 3600`. They must share an
`emptyDir` volume mounted at `/shared` in both.

**Task 9 — 3 points.** *Namespace: `mock-w`.*
Create a CronJob `reporter` that runs `busybox:1.36` with the command
`date; echo report` every five minutes, keeping at most 2 successful and 1
failed job in its history.

**Task 10 — 3 points.** *Namespace: `mock-w`.*
Label node `devops-worker2` with `tier=gold`, then create a pod `picky` running
`nginx:1.27-alpine` that will **only** schedule onto a node with that label.

**Task 11 — 3 points.** *Namespace: `mock-w`.*
Scale the `frontend` Deployment from task 7 to 5 replicas **without editing any
YAML file**, then record the change so `kubectl rollout history` shows a reason.

### Services & Networking — 20 points

**Task 12 — 4 points.** *Namespace: `mock-n`.*
Expose the existing `web` Deployment with a ClusterIP Service named `web-svc` on
port 80, targeting the container's named port `http`.

**Task 13 — 4 points.** *Namespace: `mock-n`.*
Create a NodePort Service `web-np` for the same Deployment, on node port
`30333`, that **preserves the client's source IP**.

**Task 14 — 4 points.** *Namespace: `mock-n`.*
Create a headless Service `web-hl` for the same Deployment, and prove from a pod
that it returns one address per ready endpoint rather than a single ClusterIP.
Write the number of addresses returned to `/tmp/mock-hl-count.txt` in that pod.

**Task 15 — 4 points.** *Namespace: `mock-n`.*
Write a NetworkPolicy named `deny-all-ingress` that denies all incoming traffic
to every pod in `mock-n`. **Do not** add any allow rules.

**Task 16 — 4 points.** *Cluster-wide.*
Find the ClusterIP of the `kube-dns` Service and the name of every CoreDNS pod,
and write them to `/tmp/mock-dns.txt` on your workstation, one per line, with
the ClusterIP first.

### Storage — 10 points

**Task 17 — 10 points.** *Namespace: `mock-s`.*
Create a PersistentVolumeClaim `data` requesting 200Mi with `ReadWriteOnce` from
the cluster's default StorageClass, and a pod `writer` running `busybox:1.36`
that mounts it at `/data`, writes the string `mock-exam-ok` into
`/data/proof.txt`, and then sleeps. Prove the file survives the pod being
deleted and recreated.

### Troubleshooting — 30 points

> **These five namespaces already contain something broken.** Nothing tells you
> what. Fix each so the stated condition is true.

**Task 18 — 6 points.** *Namespace: `mock-t1`.*
The `web` Service returns nothing. Make `curl http://web` from the `client` pod
in that namespace return `200`.

**Task 19 — 6 points.** *Namespace: `mock-t2`.*
The `api` Deployment has 0 available replicas. Make all 2 replicas `Ready`.

**Task 20 — 6 points.** *Namespace: `mock-t3`.*
The `cache` pod will not start. Make it `Running` and `1/1`.

**Task 21 — 6 points.** *Namespace: `mock-t4`.*
The `worker` Deployment's pods cannot be scheduled. Make all 3 `Running`.
**Do not remove the pods' tolerations or affinity** — the workload's requirements
are correct; something about the cluster is not.

**Task 22 — 3 points.** *Namespace: `mock-t5`.*
The `reader` ServiceAccount is supposed to be able to list pods in `mock-t5` and
cannot. Grant it exactly that, without changing anything else.

**Task 23 — 3 points.** *Cluster-wide.*
Write the name of every node that is **not** currently schedulable to
`/tmp/mock-unschedulable.txt`, one per line. If there are none, the file must be
empty but must exist.

---

## Part 4 - Grading

```bash
bash solution/grade.sh
```

```
== Cluster Architecture, Installation & Configuration ==
  [4/4]  Task 1  ServiceAccount + Role + RoleBinding
  [0/4]  Task 2  auditor can read everything, write nothing
  ...
== SCORE ==
  Cluster Architecture ....  21 / 25
  Workloads & Scheduling ..  15 / 15
  Services & Networking ...  16 / 20
  Storage .................  10 / 10
  Troubleshooting .........  18 / 30
  ------------------------------------
  TOTAL ...................  80 / 100     PASS (66 required)
```

**Read the per-domain lines, not the total.** A pass with 18/30 in
troubleshooting means the real exam will be much harder than this one, because
troubleshooting is 30% of it and the tasks are less friendly.

### Cleanup

```bash
bash solution/setup-mock.sh clean
```

---

## Part 5 - After the track

**This is the last assignment.** If you have worked through the 21 Days and all
33 CKA assignments, you have:

- built a cluster from nothing with `kubeadm`, and taken one below etcd quorum
- issued certificates by hand and diagnosed a control plane that would not start
- written a CNI config, a CRD, a controller, an admission webhook and a Helm
  chart
- broken the cluster eight ways without being told which

**What is left is speed and repetition**, and both come from the same two
things:

```bash
bash cka/31-troubleshooting/solution/break.sh random    # diagnosis under uncertainty
bash cka/32-jsonpath/solution/check-drills.sh           # extraction without thinking
bash cka/33-mock-exam/solution/setup-mock.sh            # this, timed, again
```

**Do the mock exam three times, a week apart.** The first tells you what you do
not know; the second tells you what you did not remember; the third tells you
whether you are fast enough.

### The exam-day checklist

```
Before:
  [ ] the exam's own environment check, days in advance
  [ ] a cleared desk, ID ready, no second monitor
  [ ] one browser tab on kubernetes.io/docs

First 60 seconds:
  [ ] alias k=kubectl
  [ ] export do="--dry-run=client -o yaml"
  [ ] export now="--force --grace-period=0"

Every task:
  [ ] READ THE CONTEXT LINE and switch to it
  [ ] read the namespace
  [ ] generate YAML, do not type it
  [ ] verify with kubectl get / describe before moving on
  [ ] if you cannot start it in 90 seconds, flag it and move on

Last 15 minutes:
  [ ] go back to the flagged tasks
  [ ] re-verify anything you were unsure of
```

---

**Previous:** [CKA 32 — JSONPath and Output Formatting](../32-jsonpath/)
**This is the end of the CKA track.** Back to
[the curriculum](../CURRICULUM.md) · [the main course](../../README.md)
