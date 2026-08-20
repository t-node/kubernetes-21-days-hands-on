#!/usr/bin/env bash
# Turn encryption at rest OFF, in the only safe order.
#
#   bash solution/disable-encryption.sh
#
# The order is the reverse of enabling, and it matters just as much:
#   1. identity FIRST  -> new writes are plaintext, old keys still readable
#   2. restart
#   3. rewrite every Secret -> nothing encrypted remains
#   4. only now remove the flag, the mount, the volume and the key file
#
# Deleting the key file first would leave the API server configured to read a
# file that no longer exists -- it would restart and never come back.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "${HERE}/_apiserver-lib.sh"

docker exec "$CP" test -f "$ENC_FILE" || { echo "encryption is not enabled -- nothing to do"; exit 0; }
backup_manifest

echo "==> 1/4 moving identity to the front"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
read_enc > "$WORK/enc.yaml"
python - "$WORK/enc.yaml" <<'PY'
import sys, yaml
path = sys.argv[1]
doc = yaml.safe_load(open(path))
for rule in doc["resources"]:
    provs = [p for p in rule["providers"] if "identity" not in p]
    rule["providers"] = [{"identity": {}}] + provs
yaml.safe_dump(doc, open(path, "w", newline="\n"), default_flow_style=False, sort_keys=False)
print("    identity is now first; the old keys stay for decryption")
PY
write_enc < "$WORK/enc.yaml"
restart_apiserver

echo "==> 2/4 rewriting every Secret as plaintext"
kubectl get secrets -A -o json | kubectl replace -f - >/dev/null
echo "    done"

echo "==> 3/4 removing the flag, the volumeMount and the volume"
docker cp "$CP:$MANIFEST" "$WORK/api.yaml"
python - "$WORK/api.yaml" <<'PY'
import sys, yaml
path = sys.argv[1]
doc = yaml.safe_load(open(path))
c = doc["spec"]["containers"][0]
c["command"] = [a for a in c["command"] if not a.startswith("--encryption-provider-config")]
c["volumeMounts"] = [m for m in c.get("volumeMounts", []) if m.get("name") != "enc"]
doc["spec"]["volumes"] = [v for v in doc["spec"].get("volumes", []) if v.get("name") != "enc"]
yaml.safe_dump(doc, open(path, "w", newline="\n"), default_flow_style=False, sort_keys=False)
print("    manifest cleaned")
PY
docker cp "$WORK/api.yaml" "$CP:$MANIFEST"
wait_ready

echo "==> 4/4 deleting the key material"
docker exec "$CP" rm -rf "$ENC_DIR"
echo "    ${ENC_DIR} removed"

echo
echo "Encryption is off and nothing encrypted remains in etcd."
echo "Confirm:  docker exec ${CP} grep -c encryption-provider ${MANIFEST}    # 0"
