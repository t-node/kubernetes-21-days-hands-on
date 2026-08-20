#!/usr/bin/env bash
# Enable encryption at rest for Secrets on the kind control-plane node.
#
#   bash solution/enable-encryption.sh
#
# By hand this is six steps: generate a key, write the config, put it on the
# node, add the flag, add the volume and the volumeMount, restart.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "${HERE}/_apiserver-lib.sh"

backup_manifest

echo "==> 1/4 generating a 32-byte key"
KEY=$(head -c 32 /dev/urandom | base64 | tr -d '\n')
echo "    key1 = ${KEY}"

echo "==> 2/4 writing ${ENC_FILE} on ${CP} (mode 600)"
sed "s|KEY1_PLACEHOLDER|${KEY}|" "${HERE}/encryption-config.yaml" | write_enc
docker exec "$CP" head -n 20 "$ENC_FILE" | tail -n 12

echo "==> 3/4 patching the API server manifest: flag + volume + volumeMount"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
docker cp "$CP:$MANIFEST" "$WORK/api.yaml"

python - "$WORK/api.yaml" "$ENC_FILE" "$ENC_DIR" <<'PY'
import sys, yaml
path, enc_file, enc_dir = sys.argv[1:4]
doc = yaml.safe_load(open(path))
c = doc["spec"]["containers"][0]

flag = "--encryption-provider-config=" + enc_file
cmd = c["command"]
cmd = [a for a in cmd if not a.startswith("--encryption-provider-config=")]
cmd.append(flag)
c["command"] = cmd

mounts = c.setdefault("volumeMounts", [])
if not any(m.get("name") == "enc" for m in mounts):
    mounts.append({"name": "enc", "mountPath": enc_dir, "readOnly": True})

vols = doc["spec"].setdefault("volumes", [])
if not any(v.get("name") == "enc" for v in vols):
    vols.append({"name": "enc",
                 "hostPath": {"path": enc_dir, "type": "DirectoryOrCreate"}})

yaml.safe_dump(doc, open(path, "w", newline="\n"), default_flow_style=False, sort_keys=False)
print("    flag, volume and volumeMount are in place")
PY

docker cp "$WORK/api.yaml" "$CP:$MANIFEST"

echo "==> 4/4 waiting for the API server to come back with encryption on"
wait_ready
docker exec "$CP" sh -c "ps aux | grep [k]ube-apiserver | xargs -n1 | grep encryption"

echo
echo "done. New Secret writes are now encrypted with aescbc/key1."
echo "Existing Secrets are STILL PLAINTEXT until you run:"
echo "   kubectl get secrets -A -o json | kubectl replace -f -"
