#!/usr/bin/env bash
# Render the issuer manifests for one Kubernetes cluster.
#
#   scripts/render.sh k8s-prod | kubectl apply -f -
#
# The argument is the name given to make-token.sh (the bot name); the join token
# is <name>-issuer. The Teleport proxy address and cluster name are read from
# the active tsh profile, and the tbot version from the proxy. Override any of
# them with environment variables:
#
#   PROXY_ADDR        Teleport Proxy Service address, host:port
#   TELEPORT_CLUSTER  Teleport cluster name (the projected token's audience)
#   TOKEN_NAME        join token name (default: <name>-issuer)
#   TBOT_VERSION      tbot image tag (default: the proxy's server_version)
#   CSI_DRIVER_VERSION, CSI_REGISTRAR_VERSION   SPIFFE CSI driver and registrar tags
#   WITH_CSI=0        omit the CSI driver (consumers then need hostPath and a privileged namespace)
set -euo pipefail
CSI_DRIVER_VERSION="${CSI_DRIVER_VERSION:-0.2.13}"
CSI_REGISTRAR_VERSION="${CSI_REGISTRAR_VERSION:-v2.18.0}"
WITH_CSI="${WITH_CSI:-1}"

here="$(cd "$(dirname "$0")/.." && pwd)"
name="${1:-}"
TOKEN_NAME="${TOKEN_NAME:-${name:+${name}-issuer}}"
: "${TOKEN_NAME:?usage: render.sh <name>   (the name given to make-token.sh)}"

if [ -z "${PROXY_ADDR:-}" ] || [ -z "${TELEPORT_CLUSTER:-}" ]; then
  status=$(tsh status --format=json 2>/dev/null || true)
  PROXY_ADDR="${PROXY_ADDR:-$(printf '%s' "$status" | jq -r '.active.profile_url // empty' | sed 's|^https://||')}"
  TELEPORT_CLUSTER="${TELEPORT_CLUSTER:-$(printf '%s' "$status" | jq -r '.active.cluster // empty')}"
fi
: "${PROXY_ADDR:?render.sh: not logged in; run tsh login or set PROXY_ADDR (host:port)}"
: "${TELEPORT_CLUSTER:?render.sh: not logged in; run tsh login or set TELEPORT_CLUSTER}"

if [ -z "${TBOT_VERSION:-}" ]; then
  TBOT_VERSION=$(curl -fsS --max-time 5 "https://${PROXY_ADDR}/webapi/ping" | sed -n 's/.*"server_version":"\([^"]*\)".*/\1/p')
  [ -n "$TBOT_VERSION" ] || { echo "render.sh: could not read server_version from ${PROXY_ADDR}; set TBOT_VERSION" >&2; exit 1; }
fi

files="namespace rbac configmap daemonset"
[ "$WITH_CSI" = "1" ] && files="$files csi-driver"
for f in $files; do
  sed -e "s|\${PROXY_ADDR}|${PROXY_ADDR}|g" \
      -e "s|\${TOKEN_NAME}|${TOKEN_NAME}|g" \
      -e "s|\${TELEPORT_CLUSTER}|${TELEPORT_CLUSTER}|g" \
      -e "s|\${TBOT_VERSION}|${TBOT_VERSION}|g" \
      -e "s|\${CSI_DRIVER_VERSION}|${CSI_DRIVER_VERSION}|g" \
      -e "s|\${CSI_REGISTRAR_VERSION}|${CSI_REGISTRAR_VERSION}|g" \
      "${here}/k8s/${f}.yaml"
  echo '---'
done
