# Day 21 solution — the drills

```bash
bash break.sh              # list the scenarios
bash break.sh reset        # rebuild a known-good stack
bash break.sh 3            # break it
cat scenario-03.md         # the answer -- AFTER you have tried
```

## Rules

1. **Time yourself.** Under 5 minutes per scenario, under 15 for scenario 9.
2. **Write the diagnosis before the fix.** "The readiness probe targets a path
   that does not exist", not "I changed something and it works".
3. **Do not open the answer** until you have fixed it or spent 10 minutes.
4. **Fix the root cause.** Deleting the pod is not a fix.

## What each scenario tests

| # | Fault | Days |
|---|---|---|
| 1 | Service selector does not match pod labels | 04, 06 |
| 2 | `:latest` tag + `imagePullPolicy: Always` on a kind-loaded image | 05, 08 |
| 3 | Wrong hostname in a ConfigMap, and env vars not live-updating | 09, 12 |
| 4 | PVC naming a StorageClass that does not exist | 14 |
| 5 | Readiness probe on `/healthz` when the route is `/health` | 06, 13 |
| 6 | Memory limit below the runtime's floor → OOMKilled, exit 137 | 16 |
| 7 | CPU requests too large → Pending on idle nodes | 16, 18 |
| 8 | Wrong `apiGroups` in a Role — silent, no error at apply time | 19 |
| 9 | **Three at once**: probe timing, wrong DB name, wrong targetPort | many |

## If a scenario leaves the cluster wedged

```bash
bash break.sh reset
```

Rebuilding from scratch takes about 90 seconds. That it is that easy is itself a
result of everything you built over the previous twenty days.
