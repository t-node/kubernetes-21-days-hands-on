# CKA 32 solution

> The twenty drills are answered by running `bash solution/check-drills.sh`,
> which prints the reference command **and its output** for each. This file
> answers the challenges and explains the non-obvious ones.

---

## Notes on the drills

**Task 8 — the filter.** The syntax that catches people is the quoting:

```bash
kubectl get pods -n cka32 -o jsonpath='{range .items[?(@.spec.nodeName=="devops-worker")]}{.metadata.name}{"\n"}{end}'
```

**Double quotes inside single quotes**, and `@` is the current element. The
filter goes where the index would.

**Task 9 — two ways, and one is better.**

```bash
kubectl get pods -n cka32 -l tier=frontend -o name                       # preferred
kubectl get pods -n cka32 -o jsonpath='{range .items[?(@.metadata.labels.tier=="frontend")]}...'
```

**Use the label selector.** It is shorter, it runs **server-side** so the API
sends less data, and a typo produces an obviously empty result rather than a
silently wrong one. **Reach for `-l` and `--field-selector` before JSONPath
filters** — a JSONPath filter is for fields no selector supports.

**Task 16 — the escaped key.** This is the one worth practising until it is
automatic:

```bash
kubectl get deploy web -n cka32 -o jsonpath='{.metadata.annotations.example\.com/owner}{"\n"}'
```

Without the `\.` it returns nothing, silently — the query is read as
`.annotations.example.com.owner`, four levels that do not exist.

**Task 20 — nodes without taints still appear.**

```bash
kubectl get nodes -o custom-columns=NODE:.metadata.name,TAINTS:.spec.taints[*].key
```

`custom-columns` prints `<none>` for a missing field rather than skipping the
row, which is exactly what the task asked for. **A `range` over
`.spec.taints[*]` would omit untainted nodes entirely** — a good illustration of
when `custom-columns` is not merely nicer but *correct*.

---

## Challenge answers

### C1 - Convert five commands

**1.** `kubectl get pods -o wide | grep devops-worker | awk '{print $1}'`

```bash
kubectl get pods --field-selector=spec.nodeName=devops-worker -o name
```

**Better as one command.** The field selector is server-side and exact;
`grep devops-worker` would also match a pod *named* `devops-worker-thing`.

**2.** `kubectl get nodes -o yaml | grep -A3 capacity | grep cpu`

```bash
kubectl get nodes -o custom-columns=NODE:.metadata.name,CPU:.status.capacity.cpu
```

**Much better.** The pipeline loses which node each number belongs to; the
`custom-columns` version keeps them together.

**3.** `kubectl get pods -o json | jq -r '.items[].spec.containers[].image' | sort -u`

```bash
kubectl get pods -A -o jsonpath='{.items[*].spec.containers[*].image}' | tr ' ' '\n' | sort -u
```

**Better left as a pipeline** — for the `sort -u` part. JSONPath cannot
deduplicate or sort a flattened list, so you need *some* shell. The improvement
is only dropping the `jq` dependency, which matters in an exam and not much
otherwise.

**4.** `kubectl get svc | grep NodePort`

```bash
kubectl get svc -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,TYPE:.spec.type,NODEPORT:.spec.ports[*].nodePort \
  | grep NodePort
```

...which is **worse**. There is no field selector for `spec.type` and JSONPath
filters cannot easily produce a clean table of only the matches.

**Leave this one as a pipeline.** `kubectl get svc -A | grep NodePort` is the
right answer, and recognising that is part of the skill — **not every command
should be one command.**

**5.** `kubectl get pods -A | grep -v Running | grep -v Completed`

```bash
kubectl get pods -A --field-selector=status.phase!=Running
```

**Better as one command**, and more correct: the pipeline also drops the header
line and would match a pod whose *name* contains "Running".

Note `Completed` pods have phase `Succeeded`, so exclude both if you want them
gone:

```bash
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
```

**The summary: 1, 2 and 5 are genuinely better as one command; 3 needs a shell
for the sort; 4 is better left alone.**

### C2 - Why is it empty?

**1.** `kubectl get pods -o jsonpath='{.metadata.name}'`

**A list has no `.metadata.name`.** `kubectl get pods` returns a `List` (32.2).

```bash
kubectl get pods -o jsonpath='{.items[*].metadata.name}{"\n"}'
```

**2.** `kubectl get node devops-worker -o jsonpath='{.items[0].status.capacity.cpu}'`

**The opposite mistake.** A single named object has no `.items`.

```bash
kubectl get node devops-worker -o jsonpath='{.status.capacity.cpu}{"\n"}'
```

**Those two are the same error in both directions**, and between them they cause
most empty output.

**3.** `...-o jsonpath='{.metadata.annotations.example.com/owner}'`

**Unescaped dots** (32.3) — read as `.annotations.example.com.owner`.

```bash
kubectl get deploy web -n cka32 -o jsonpath='{.metadata.annotations.example\.com/owner}{"\n"}'
```

**4.** `...-o jsonpath='{range .items[*]}{.metadata.name}\n{end}'`

**Not empty — malformed.** The `\n` is *outside* the braces, so it prints as the
literal characters `\` and `n`:

```
devops-control-plane\ndevops-worker\n...
```

```bash
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
```

**5.** `...items[?(@.metadata.labels.tier=='frontend')]...`

**The inner single quotes end the shell's quoting**, so the shell mangles the
expression before `kubectl` sees it. JSONPath wants **double** quotes inside:

```bash
kubectl get pods -n cka32 -o jsonpath='{.items[?(@.metadata.labels.tier=="frontend")].metadata.name}{"\n"}'
```

**Every one of these exits 0.** An empty result is not an error (32.2), which is
why a typo is silent and why you check the path against `-o json` first.

### C3 - Pick the tool

**1. One Service's ClusterIP into a shell variable — `jsonpath`.**

```bash
IP=$(kubectl get svc web -n cka32 -o jsonpath='{.spec.clusterIP}')
```

**A single scalar with no decoration** is exactly what `jsonpath` is for.
`custom-columns` would give you a header to strip; `-o wide` would need `awk`.

**2. A table of PVCs — `custom-columns`.**

```bash
kubectl get pvc -A -o custom-columns=\
NS:.metadata.namespace,NAME:.metadata.name,SIZE:.spec.resources.requests.storage,\
CLASS:.spec.storageClassName,STATUS:.status.phase
```

**One row per object with aligned headers**, and no `range`/`end` to get wrong.

**3. Delete failed pods — `-o name` plus a pipeline.**

```bash
kubectl get pods -n dev --field-selector=status.phase=Failed -o name | xargs -r kubectl delete -n dev
```

**`-o name` exists for this**: it emits `pod/x`, which is exactly what `kubectl
delete` accepts. Note the field selector does the filtering server-side.

Shorter still, and worth knowing:

```bash
kubectl delete pods -n dev --field-selector=status.phase=Failed
```

**4. Five most recently created pods — `--sort-by` plus `tail`.**

```bash
kubectl get pods -A --sort-by=.metadata.creationTimestamp | tail -5
```

**`--sort-by` cannot reverse or limit**, so the shell does the last step. Trying
to express "top five" in JSONPath is not worth the attempt.

**5. Images from Docker Hub — `jsonpath` plus a pipeline.**

```bash
kubectl get pods -A -o jsonpath='{.items[*].spec.containers[*].image}' \
  | tr ' ' '\n' | grep -v '\.' | sort -u
```

**JSONPath has no string functions** (32.7), so "does this image name contain a
registry host" cannot be expressed in it. The heuristic above — a Docker Hub
reference has no dot before the first slash — belongs in `grep`.

**The pattern across all five: use `kubectl` for selecting and shaping, and the
shell for sorting, limiting and string matching.** Trying to do the second group
in JSONPath is where people lose time.

### C4 - The exam-day question

> *Find the pod in namespace `dev` with the highest CPU request and write its
> name to `/opt/answer.txt`.*

**1. One command:**

```bash
kubectl get pods -n dev -o custom-columns=\
NAME:.metadata.name,CPU:.spec.containers[*].resources.requests.cpu --no-headers \
  | sort -k2 -h -r | head -1 | awk '{print $1}' > /opt/answer.txt
```

**2. What JSONPath cannot do here.**

**Three things, and any one of them is fatal:**

- **It cannot sort.** There is no ordering operator in JSONPath.
- **It cannot compare numbers**, so "the highest" is inexpressible even with a
  filter (32.7).
- **It cannot parse `100m` as a quantity.** CPU requests are Kubernetes
  quantities — `100m`, `1`, `1500m` — and a naive lexical sort puts `250m` above
  `1`.

**That last one is the trap.** `sort -h` handles suffixes better than `sort -n`,
but the honest fix is to normalise the units first if the values are mixed:

```bash
kubectl get pods -n dev -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.containers[0].resources.requests.cpu}{"\n"}{end}' \
  | awk '{v=$2; sub(/m$/,"",v); if ($2 ~ /m$/) v=v/1000; print v, $1}' \
  | sort -rn | head -1 | awk '{print $2}'
```

**3. A second solution — `go-template`, or `jq`:**

```bash
kubectl get pods -n dev -o json \
  | jq -r '.items | map({n:.metadata.name, c:(.spec.containers[0].resources.requests.cpu)}) | sort_by(.c) | last.n'
```

**4. What I would actually type.**

**The first one, with `sort -k2 -h -r`** — and then I would *look at the output*
before writing the file:

```bash
kubectl get pods -n dev -o custom-columns=NAME:.metadata.name,CPU:.spec.containers[*].resources.requests.cpu
```

**Print it, read it, then answer.** In a namespace with five pods the sort is a
formality and eyeballing the table is faster and safer than getting the units
right under time pressure. The scripted version matters when there are fifty.

**The general exam lesson: produce the table, look at it, then extract.** A
one-liner that is wrong in a way you did not see costs the whole question; a
two-step that you verified costs ten seconds.

### C5 - Build a diagnostic one-liner

```bash
kubectl get pods -A --field-selector=status.phase!=Running -o custom-columns=\
NS:.metadata.namespace,\
POD:.metadata.name,\
PHASE:.status.phase,\
NODE:.spec.nodeName,\
REASON:.status.containerStatuses[0].state.waiting.reason
```

**Each part:**

| Part | Does |
|---|---|
| `-A` | every namespace |
| `--field-selector=status.phase!=Running` | filters **server-side**, so the API sends only what you need |
| `-o custom-columns=` | one row per pod, with a header |
| `NS:.metadata.namespace` | a column name, then the path within each item |
| `.status.containerStatuses[0].state.waiting.reason` | the reason a container is not running -- `ImagePullBackOff`, `CrashLoopBackOff`, `CreateContainerConfigError` |

**What breaks when some pods have no container statuses.**

A `Pending` pod that was never scheduled has **no `containerStatuses` at all**,
because no kubelet has claimed it (31.7). The path resolves to nothing and
`custom-columns` prints `<none>` — **which is the correct behaviour and also the
information you want**: a `<none>` in the REASON column next to `Pending` tells
you the pod never reached a node.

Two adjustments if you need more:

**Cover terminated containers too**, since a pod that ran and exited has
`state.terminated`, not `state.waiting`:

```bash
  REASON:.status.containerStatuses[0].state.waiting.reason,\
  EXIT:.status.containerStatuses[0].state.terminated.exitCode
```

**And cover the scheduling case**, which lives in the pod's conditions rather
than in any container:

```bash
  SCHED:.status.conditions[?(@.type=="PodScheduled")].reason
```

**The thing not to do is switch to a `range`** to handle the missing field.
`custom-columns` degrades to `<none>`; a `range` over
`.status.containerStatuses[*]` **silently omits the row entirely** — so the pods
with no containers, which are the ones you most want to see, disappear from your
diagnostic. Same trap as drill 20.

---

## Files

| File | Purpose |
|---|---|
| `setup.yaml` | objects with the awkward properties real ones have -- dotted annotation keys, several containers, named ports, a NodePort, a Secret, and a pod that never becomes Ready |
| `drills.md` | twenty tasks plus four stretch tasks |
| `check-drills.sh` | runs the reference answer for each and prints its output; `check-drills.sh 8` for one |
| `verify.sh` | asserts that a representative query from each category returns the expected value |

---

## Why the setup deliberately includes a pod that never becomes Ready

`never-ready` has a readiness probe pointed at a path that does not exist, so it
sits at `0/1 Running` forever.

**Without it, several drills have no answer.** "Which pods are not Ready" and
"show me the reason from the container state" both need something to find, and a
namespace where everything works is a namespace where you cannot practise
finding what does not.

It is also the honest shape of the real task: **`Running` and `Ready` are
different**, and a query that filters on `status.phase` will not find this pod at
all. Compare:

```bash
kubectl get pods -n cka32 --field-selector=status.phase!=Running    # does NOT list it
kubectl get pods -n cka32                                            # 0/1 in the READY column
kubectl get pods -n cka32 -o custom-columns=POD:.metadata.name,\
READY:.status.conditions[?(@.type=="Ready")].status
```

**The phase is `Running`; the `Ready` condition is `False`.** Anything looking
for unhealthy workloads by phase alone misses exactly this case — which is the
most common way an application is broken in production, since it is what a
failing readiness probe produces ([CKA 23](../../23-service-networking/)).

## A note on `check-drills.sh`

It is an answer key that **runs**, rather than a list of commands to compare
against by eye. That matters for two reasons:

- **Several drills have more than one correct answer** (task 1 has three,
  task 9 has two). Seeing the output lets you confirm your version produces the
  same thing rather than matching text.
- **The output on your cluster is not the output in a book.** Node names, CPU
  counts and pod names differ, so a printed expected-output would be wrong for
  everyone.

Run it with a task number to check one at a time:

```bash
bash solution/check-drills.sh 16
```
