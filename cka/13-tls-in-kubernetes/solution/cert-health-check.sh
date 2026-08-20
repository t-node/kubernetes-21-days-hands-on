#!/usr/bin/env bash
# Build the certificate inventory the lecture describes as a spreadsheet.
#
#   bash solution/cert-health-check.sh
#
# For every certificate on the control-plane node: subject CN, organisation,
# issuer, expiry and days remaining. Anything under 30 days is flagged.
set -uo pipefail
CP=${CP:-devops-control-plane}

field() {  # field <file> <openssl-flag> ; prints the value after the first '='
  docker exec "$CP" openssl x509 -in "$1" -noout "$2" 2>/dev/null | sed 's/^[^=]*=//' | sed 's/^ *//'
}

printf "%-46s %-30s %-14s %-12s %-14s %s\n" FILE "SUBJECT CN" "ORG" "ISSUER" "EXPIRES" "DAYS"
printf "%-46s %-30s %-14s %-12s %-14s %s\n" \
  "----------------------------------------------" "------------------------------" \
  "--------------" "------------" "--------------" "----"

FILES=$(docker exec "$CP" sh -c 'ls /etc/kubernetes/pki/*.crt /etc/kubernetes/pki/etcd/*.crt 2>/dev/null')

now=$(date +%s)
for f in $FILES; do
  subj=$(docker exec "$CP" openssl x509 -in "$f" -noout -subject 2>/dev/null)
  cn=$(echo "$subj" | grep -o 'CN *= *[^,]*' | head -1 | sed 's/CN *= *//')
  org=$(echo "$subj" | grep -o 'O *= *[^,]*' | head -1 | sed 's/O *= *//')
  iss=$(docker exec "$CP" openssl x509 -in "$f" -noout -issuer 2>/dev/null \
        | grep -o 'CN *= *[^,]*' | head -1 | sed 's/CN *= *//')
  notafter=$(docker exec "$CP" openssl x509 -in "$f" -noout -enddate 2>/dev/null | sed 's/notAfter=//')

  # date arithmetic differs between GNU and BSD date; try both, fall back to blank
  exp=$(date -d "$notafter" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$notafter" +%s 2>/dev/null || echo "")
  if [ -n "$exp" ]; then
    days=$(( (exp - now) / 86400 ))
    short=$(date -d "$notafter" +%Y-%m-%d 2>/dev/null || echo "$notafter")
  else
    days="?"; short="$notafter"
  fi

  flag=""
  case "$days" in
    ''|*[!0-9-]*) ;;
    *) [ "$days" -lt 30 ] && flag="  <-- RENEW" ;;
  esac

  printf "%-46s %-30s %-14s %-12s %-14s %s%s\n" \
    "${f#/etc/kubernetes/}" "${cn:--}" "${org:--}" "${iss:--}" "$short" "$days" "$flag"
done

echo
echo "Two issuers should appear above: 'kubernetes' and 'etcd-ca'."
echo "Any certificate whose ISSUER is not one of them was not signed by this cluster."
echo
echo "kubeadm's own view (authoritative, and it also covers the kubeconfigs):"
docker exec "$CP" kubeadm certs check-expiration 2>/dev/null | sed 's/^/    /'
