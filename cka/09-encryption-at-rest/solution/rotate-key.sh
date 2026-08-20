#!/usr/bin/env bash
# Key rotation, one step at a time -- because the ORDER is the whole lesson.
#
#   bash solution/rotate-key.sh add       # 1. new key SECOND (decrypt-only)
#   bash solution/rotate-key.sh promote   # 2. new key FIRST  (now encrypts)
#   ... then: kubectl get secrets -A -o json | kubectl replace -f -
#   bash solution/rotate-key.sh drop      # 4. remove the old key
#
# Each step restarts the API server. Step 3 is deliberately NOT in this script:
# you must run the rewrite yourself, because skipping it is what destroys data.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "${HERE}/_apiserver-lib.sh"

STEP=${1:-}
case "$STEP" in add|promote|drop) ;; *) echo "usage: $0 <add|promote|drop>"; exit 1 ;; esac

docker exec "$CP" test -f "$ENC_FILE" || { echo "no ${ENC_FILE} -- run enable-encryption.sh first"; exit 1; }

NEWKEY=""
[ "$STEP" = "add" ] && NEWKEY=$(head -c 32 /dev/urandom | base64 | tr -d '\n')

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
read_enc > "$WORK/enc.yaml"

python - "$WORK/enc.yaml" "$STEP" "$NEWKEY" <<'PY'
import sys, yaml
path, step, newkey = sys.argv[1], sys.argv[2], sys.argv[3]
doc = yaml.safe_load(open(path))
rule = doc["resources"][0]
provs = rule["providers"]

def enc_provider(ps):
    for p in ps:
        for name in ("aescbc", "aesgcm", "secretbox"):
            if name in p:
                return name, p
    raise SystemExit("no local-key provider found in the configuration")

name, prov = enc_provider(provs)
keys = prov[name]["keys"]

if step == "add":
    if any(k["name"] == "key2" for k in keys):
        print("    key2 already present")
    else:
        keys.append({"name": "key2", "secret": newkey})
        print("    key2 appended SECOND -- every API server can now DECRYPT it,")
        print("    but key1 is still first so nothing new is encrypted with it.")
elif step == "promote":
    keys.sort(key=lambda k: 0 if k["name"] == "key2" else 1)
    print("    key2 moved FIRST -- new writes are encrypted with key2 from now on.")
    print("    key1 stays in the list so older records remain readable.")
else:  # drop
    remaining = [k for k in keys if k["name"] != "key1"]
    if len(remaining) == len(keys):
        print("    key1 already gone")
    elif not remaining:
        raise SystemExit("refusing to remove the only key")
    else:
        prov[name]["keys"] = remaining
        print("    key1 REMOVED. Anything still encrypted with key1 is now")
        print("    unreadable -- this is only safe after the rewrite step.")

yaml.safe_dump(doc, open(path, "w", newline="\n"), default_flow_style=False, sort_keys=False)
PY

write_enc < "$WORK/enc.yaml"
echo "-- new configuration on ${CP}:"
read_enc | sed 's/^/     /'

# Without --encryption-provider-config-automatic-reload the API server only
# reads this file at startup, so the change needs a restart.
restart_apiserver

case "$STEP" in
  promote) echo; echo "NEXT: kubectl get secrets -A -o json | kubectl replace -f -" ;;
  add)     echo; echo "NEXT: bash solution/rotate-key.sh promote" ;;
  drop)    echo; echo "Rotation complete." ;;
esac
