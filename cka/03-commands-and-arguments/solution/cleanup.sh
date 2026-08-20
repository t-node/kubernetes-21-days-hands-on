#!/usr/bin/env bash
# Remove everything CKA 03 creates.
kubectl delete -f 01-four-combinations.yaml --ignore-not-found
kubectl delete pod sleeper-quoted sleeper-unquoted shell-form \
  timer echoer r1 r2 exits-immediately broken-fe --ignore-not-found
