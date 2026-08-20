# CKA 32 — the drills

Twenty tasks. **Time yourself: the target is under 90 seconds each** once you
have the syntax. Do not read `README.md` in this directory until you are done.

Setup, once:

```bash
kubectl apply -f solution/setup.yaml
kubectl -n cka32 rollout status deployment/web --timeout=120s
kubectl label node devops-worker cka32-disk=ssd --overwrite
kubectl taint node devops-worker cka32-role=batch:NoSchedule --overwrite
```

---

## Basics

**1.** Print the name of every node, one per line.

**2.** Print only the name of the *first* node.

**3.** Print every node's name and its CPU capacity, tab separated, one per line.

**4.** Do task 3 as a table with headers `NODE` and `CPU`.

**5.** Print every node's kubelet version, OS image and container-runtime
version as a table.

## Selecting and filtering

**6.** Print the names of all pods in `cka32`, one per line.

**7.** Print the name and node of every pod in `cka32`, as a table.

**8.** Print only the names of pods in `cka32` that are running on
`devops-worker`. *(Use a JSONPath filter, not `grep`.)*

**9.** Print the names of every pod in `cka32` with the label `tier=frontend`.
*(Two ways: a label selector, and a JSONPath filter. Which is better?)*

**10.** Print the names of all pods in the cluster that are **not** `Running`.

## Nested and repeated fields

**11.** Print every image used by the `web` Deployment's pod template.

**12.** Print each pod in `cka32` with all of its container images on one line.

**13.** Print the container name and CPU request for every container in the
`web` Deployment, as a table.

**14.** Print every named port on the `web` Deployment's first container.

**15.** Print the `nodePort` of the `web` Service.

## Escaping and awkward keys

**16.** Print the `example.com/owner` annotation from the `web` Deployment.

**17.** Print the `kubernetes.io/hostname` label of every node, as a table with
the node name.

**18.** Print the value of the `password` key in the `app-secret` Secret, decoded.

## Sorting and combining

**19.** List the pods in `cka32` sorted by creation time, newest last.

**20.** Print every node's name and any taints it has. *(Nodes without taints
should still appear.)*

---

## Stretch

**S1.** Print the names of all nodes that have a taint with effect `NoSchedule`.

**S2.** Print every Deployment in the cluster whose replica count is greater than
2. *(Hint: JSONPath cannot compare numbers — you need `go-template`.)*

**S3.** Produce a table of every container in `cka32` — pod name, container name,
image — with one row per **container**, not per pod.

**S4.** Write task 4 as a `custom-columns-file` and run it with no shell quoting
at all.
