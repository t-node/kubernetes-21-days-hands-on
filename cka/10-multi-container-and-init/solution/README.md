# CKA 10 solution

## Challenge answers

### C1 - Choose the pattern

| # | Workload | Pattern | Why |
|---|---|---|---|
| 1 | metrics exporter | **native sidecar** | must be up before the app to avoid gaps, and must run for the pod's life; it also reaches the app on `localhost` |
| 2 | schema migration | **init container** | it must *finish* before traffic, and finishing is the whole signal |
| 3 | certificate fetcher | **native sidecar** | it recurs forever, so it cannot be an init container, and it must be ready before the app reads the first cert |
| 4 | `chown` a volume | **init container** | one action, exits, and it needs to run as root while the app does not |
| 5 | Redis for three Deployments | **none of them** | this is a separate Deployment plus a Service |

**Number 5 is the trick.** Three Deployments sharing one cache is the textbook
case for *not* using a multi-container pod: you would get one Redis per app
replica, each with its own private cache, scaling with the wrong workload and
sharing nothing. The test from 10.2 answers it — you would absolutely want to
scale Redis independently, so it is its own Deployment.

Number 1 deserves a note: a plain co-located container *works*, and this is how
every exporter was deployed before 1.29. It just loses the first few seconds of
metrics on every pod start. Native sidecar is strictly better where available.

Number 4 is worth doing right: an init container is how you fix volume
permissions for a non-root app without granting the app itself root. It runs as
UID 0, `chown`s the mount, and exits — root exists for one second in the pod's
life instead of for its duration. (The alternative, `fsGroup` in the pod
`securityContext`, is better still where the volume plugin supports it.)

### C2 - Stuck at Init:0/3

```bash
# 1. which init container is running, and what state is it in?
kubectl get pod POD -o jsonpath='{range .status.initContainerStatuses[*]}{.name}{"  "}{.state}{"\n"}{end}'

# 2. the readable version, with events at the bottom
kubectl describe pod POD | sed -n '/Init Containers:/,$p'

# 3. what is it actually doing? (Init:0/3 means the FIRST one)
kubectl logs POD -c <first-init-container-name> --tail=20

# 4. failing, or slow? RESTARTS answers this
kubectl get pod POD -o jsonpath='{.status.initContainerStatuses[0].restartCount}{"\n"}'

# 5. if it is running and silent, look inside
kubectl exec POD -c <first-init-container-name> -- ps aux
```

**`Init:0/3` means the first one — index 0 — is the one to look at.** The number
before the slash is how many have *completed*, so zero completed means container
`[0]` is still in progress.

**Failing vs slow** is decided by `restartCount` and `lastState`:

| Signal | Reading |
|---|---|
| `restartCount: 0`, state `running` | genuinely slow, or waiting on something that will never arrive |
| `restartCount > 0`, `lastState.terminated.exitCode != 0` | failing and being retried |
| STATUS shows `Init:CrashLoopBackOff` | failing, and the kubelet is now backing off |

**If the status were `Init:2/3`:** two have completed and container **`[2]`** is
the one running — so `kubectl logs POD -c <third-init-name>`. The completed ones
still have logs, and reading them is often how you find that step two produced
the wrong output that step three is now choking on:

```bash
kubectl logs POD -c <second-init-name>
```

### C3 - Sidecar failure modes

**1. A native sidecar crashes while the app runs.** It is restarted, on its own,
according to its `restartPolicy: Always` — **the app container is not touched
and the pod is not restarted**. The pod's `RESTARTS` count goes up. This is the
behaviour you want: a log shipper falling over should not take the application
down with it. Note the gap this leaves: during the restart the app keeps running
and its logs are not being shipped.

**2. A plain init container exits 1.** The kubelet applies the **pod's**
`restartPolicy`:

| Pod `restartPolicy` | Result |
|---|---|
| `Always` (default) | the init container is retried with backoff — `Init:Error` then `Init:CrashLoopBackOff` |
| `OnFailure` | same — retried |
| `Never` | the pod goes to `Failed` and stops |

**The app never starts**, in every case. That is the guarantee of an init
container, and it is why "wait for the database" is safe to express this way.

**3. The app exits 0 with pod `restartPolicy: Never`.** The kubelet **sends the
sidecar SIGTERM and the pod moves to `Succeeded`.** The sidecar's own
`restartPolicy: Always` does not apply once the main containers have finished —
the kubelet knows the pod's work is done. This is exactly the Job problem the
feature was built for: before native sidecars, a `tail -f` in
`spec.containers` kept the pod `Running` forever and the Job never completed.

**4. Why only `Always`?** Because `restartPolicy` on an init container is not a
general restart setting — it is the flag that changes *when the init sequence
considers this container done*. With `Always`, the sequence moves on once the
container has **started** rather than once it has **exited**, which is the
definition of a sidecar. `OnFailure` and `Never` would describe a container that
runs to completion, which is what an init container already is with no
`restartPolicy` at all. The other values would mean nothing, so the API rejects
them.

### C4 - Write the wait correctly

```yaml
initContainers:
  - name: wait-for-postgres
    image: busybox:1.36
    command:
      - sh
      - -c
      - |
        deadline=$(( $(date +%s) + 120 ))
        until nc -z database 5432; do
          if [ "$(date +%s)" -ge "$deadline" ]; then
            echo "gave up waiting for database:5432 after 120s" >&2
            exit 1
          fi
          echo "database:5432 not accepting connections yet"
          sleep 3
        done
        echo "database:5432 is up"
```

**`nc -z` opens a TCP connection**; `nslookup` only asks DNS. A Service has a
DNS record from the moment it is created, with or without a single endpoint
behind it — so an `nslookup` loop returns success against a Service whose pods
have never started. It proves the *name* exists, not the *database*.

**Why the timeout matters.** Without it, a typo in the Service name produces a
pod that sits at `Init:0/1` forever, looking patient rather than broken. Nothing
alerts, no event fires after the first few minutes, and `kubectl get pods` shows
a status that could equally mean "starting". With the timeout, the container
exits `1` at a known moment.

**What the pod does when it expires** depends on the pod's `restartPolicy`
(C3.2): with the default `Always` it goes `Init:Error` → `Init:CrashLoopBackOff`,
which is a visibly broken state that shows up in every dashboard and alerting
rule you have. **A failure that looks like a failure is the point.**

Two refinements for real use:

- `until nc -z database 5432; do` tests the port, but a Postgres that is
  listening and still recovering will accept the connection. If the app cannot
  tolerate that, the check belongs in the app's **readiness probe**
  ([Day 13](../../../days/day-13-health-probes/)) rather than in an init
  container — init runs once, a probe runs forever.
- Do not make the timeout shorter than your database's realistic start time, or
  you have built a crash loop that resolves itself and looks like flapping.

### C5 - Two containers, one port

**What happened: the sidecar's process binds a port that the `containerPort`
field does not describe.** `containerPort` is documentation — purely
informational metadata. It does not open, reserve, or restrict anything. The
container's actual listening socket is decided by the program inside it, and
both containers share **one network namespace** (10.1), so both bind into the
same port space. The sidecar declared `containerPort: 9100` in the YAML while
the process inside it actually listened on `8080`, which the app already had.

The two commands that confirm it:

```bash
# 1. what is ACTUALLY listening in the pod's network namespace?
kubectl exec POD -c sidecar -- netstat -tlnp
#    (or, if the image lacks netstat:)
kubectl debug POD -it --image=nicolaka/netshoot --target=app -- netstat -tlnp

# 2. what did the app say, and what does the sidecar's image really do?
kubectl logs POD -c app --previous
kubectl get pod POD -o jsonpath='{range .spec.containers[*]}{.name}{" -> "}{.ports}{"\n"}{end}'
```

The second command is the instructive one: it shows the *declared* ports, which
is what the colleague read. Comparing that against `netstat` output from inside
the namespace is the whole diagnosis — **declared ports and bound ports are
different things, and only one of them can conflict.**

The fix is to change the sidecar's actual listen address via its own
configuration (a flag or an environment variable), not by editing
`containerPort`. Editing `containerPort` changes nothing at all, which is the
next hour the colleague would otherwise have lost.

> `kubectl debug --target` shares the target container's network namespace,
> which is how you inspect sockets in an image that ships no tools. It is worth
> knowing before the exam, not during it.

---

## Files

| File | Purpose |
|---|---|
| `01-colocated.yaml` | writer + nginx sharing an `emptyDir` and `localhost` |
| `02-init-sequential.yaml` | two init containers, 10s each -- watch `Init:0/2` -> `Init:1/2` |
| `03-init-wait-for-service.yaml` | blocks at `Init:0/1` until a Service resolves |
| `04-database-service.yaml` | the Service that releases it -- no pods needed |
| `05-native-sidecar.yaml` | `initContainers` + `restartPolicy: Always`, pod `restartPolicy: Never` |
| `06-colocated-race.yaml` | the same job without ordering -- the first log line is lost |
| `07-broken-init-BAD.yaml` | `slep` instead of `sleep` -- exit 127 |
| `verify.sh` | checks every claim in Part 4 |

> **Do not `kubectl apply -f solution/`.** `07-broken-init-BAD.yaml` is meant to
> fail, and `04-database-service.yaml` must be applied *after* you have watched
> `03` block. Follow the lab steps.

---

## A note on `06-colocated-race.yaml`

The `sleep 5` in the shipper is standing in for something real: an agent reading
its configuration, resolving a collector endpoint, or establishing a TLS session
before it starts tailing. Five seconds is generous for a demo and pessimistic
for nothing — real log agents routinely take longer.

The race is not that the containers start in the *wrong* order. It is that there
**is no order** — the kubelet starts both, and which one wins depends on image
cache state, container runtime scheduling and the machine's load. It will
usually work on your laptop and fail on the busy node, which is the worst
possible failure distribution.
