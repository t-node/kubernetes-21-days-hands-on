#!/usr/bin/env bash
# CKA 09 verification. Run from the assignment directory:
#   bash solution/verify.sh
#
# It detects which state the cluster is in -- encryption ON (after Step 6) or
# decommissioned (after Step 8) -- and checks the right things for that state.
HERE="$(cd "$(dirname "$0")" && pwd)"
. "${HERE}/_apiserver-lib.sh"
pass=0; fail=0
ok() { echo "  PASS  $1"; pass=$((pass+1)); }
no() { echo "  FAIL  $1"; fail=$((fail+1)); }

raw() { etcd_cmd get "/registry/secrets/$1/$2" 2>/dev/null; }

ENABLED=0
docker exec "$CP" grep -q encryption-provider-config "$MANIFEST" 2>/dev/null && ENABLED=1

echo "== state: encryption is $([ $ENABLED -eq 1 ] && echo ON || echo OFF) =="

if [ "$ENABLED" -eq 1 ]; then
  echo "== 1. Wiring =="
  docker exec "$CP" sh -c "ps aux | grep [k]ube-apiserver | xargs -n1 | grep -q encryption-provider-config" \
    && ok "the running process carries --encryption-provider-config" \
    || no "the flag is in the manifest but not on the running process"

  docker exec "$CP" test -f "$ENC_FILE" && ok "${ENC_FILE} exists on the node" \
                                        || no "${ENC_FILE} missing"

  mode=$(docker exec "$CP" stat -c %a "$ENC_FILE" 2>/dev/null)
  [ "$mode" = "600" ] && ok "key file mode is 600" || no "key file mode is '${mode:-?}', expected 600"

  if docker exec "$CP" grep -q "name: enc" "$MANIFEST" 2>/dev/null; then
    ok "the enc volume and volumeMount are present"
  else
    no "no 'enc' volume in the manifest -- the flag would point at nothing"
  fi

  echo "== 2. Provider order =="
  first=$(read_enc 2>/dev/null | grep -A100 "providers:" | grep -m1 -E "^\s+- (aescbc|aesgcm|secretbox|identity)")
  case "$first" in
    *identity*) no "identity is FIRST -- nothing is being encrypted" ;;
    *) ok "a real provider is first:$(echo "$first" | tr -d ' -:')" ;;
  esac
  read_enc 2>/dev/null | grep -q "identity" && ok "identity is present as a fallback" \
                                            || echo "  NOTE  no identity provider -- fine only if nothing plaintext remains"

  echo "== 3. Data in etcd =="
  if raw cka09 my-secret-2 | grep -a -q "k8s:enc:"; then
    ok "my-secret-2 is stored encrypted"
  else
    no "my-secret-2 has no k8s:enc: prefix -- was it created after Step 4?"
  fi
  if raw cka09 my-secret-2 | grep -a -q "topsecret"; then
    no "the plaintext 'topsecret' is still visible in etcd"
  else
    ok "the plaintext 'topsecret' is not in the raw bytes"
  fi
  if raw cka09 my-secret | grep -a -q "supersecret"; then
    no "my-secret is still plaintext -- run: kubectl get secrets -A -o json | kubectl replace -f -"
  else
    ok "my-secret was rewritten and is now encrypted too"
  fi

  echo "== 4. The API is unaffected =="
  v=$(kubectl -n cka09 get secret my-secret -o jsonpath='{.data.key1}' 2>/dev/null | base64 -d 2>/dev/null)
  [ "$v" = "supersecret" ] && ok "the Secret still reads correctly through kubectl" \
                           || no "kubectl returned '${v:-nothing}' -- a key may have been dropped too early"
else
  echo "== decommission checks =="
  docker exec "$CP" sh -c "test ! -e $ENC_DIR" && ok "${ENC_DIR} is gone" || no "${ENC_DIR} still on the node"
  docker exec "$CP" grep -q "name: enc" "$MANIFEST" 2>/dev/null \
    && no "an 'enc' volume is still in the manifest" || ok "no leftover volume or mount"
  kubectl get --raw=/readyz >/dev/null 2>&1 && ok "the API server is healthy" || no "the API server is not ready"
  if raw cka09 my-secret | grep -a -q "supersecret"; then
    ok "Secrets were rewritten as plaintext before the key file was deleted"
  else
    no "my-secret is neither readable plaintext nor decryptable -- the key may have been removed before the rewrite"
  fi
fi

echo
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
