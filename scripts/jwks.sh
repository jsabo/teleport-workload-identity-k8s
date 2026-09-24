#!/usr/bin/env bash
# Print the current Kubernetes cluster's ServiceAccount signing keys (JWKS) as a
# single line, ready to paste into teleport/bot-token-example.yaml.
#
#   scripts/jwks.sh                  # current kubectl context
#   scripts/jwks.sh --check TOKEN    # compare with the key pinned in a Teleport token
set -euo pipefail

live=$(kubectl get --raw /openid/v1/jwks)

if [ "${1:-}" = "--check" ]; then
  token="${2:?token name}"
  pinned=$(tctl get "token/${token}" --format=json | jq -r '.[0].spec.kubernetes.static_jwks.jwks')
  live_kid=$(printf '%s' "$live" | jq -r '.keys[].kid' | sort)
  pinned_kid=$(printf '%s' "$pinned" | jq -r '.keys[].kid' | sort)
  if [ "$live_kid" = "$pinned_kid" ]; then
    echo "ok: token ${token} pins the cluster's current key(s): ${live_kid}"
  else
    echo "MISMATCH: cluster has ${live_kid}, token ${token} pins ${pinned_kid} — recreate the token" >&2
    exit 1
  fi
  exit 0
fi

printf '%s\n' "$live"
