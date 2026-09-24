#!/usr/bin/env bash
# Render the issuer manifests for one Teleport cluster and one Kubernetes cluster.
#
#   PROXY_ADDR=example.teleport.sh:443 TOKEN_NAME=k8s-prod-issuer scripts/render.sh | kubectl apply -f -
#
# Variables (all required unless noted):
#   PROXY_ADDR        Teleport Proxy Service address, host:port
#   TOKEN_NAME        join token created from teleport/bot-token-example.yaml
#   TELEPORT_CLUSTER  Teleport cluster name = the projected token's audience
#                     (default: PROXY_ADDR without the port)
#   TBOT_VERSION      tbot image tag (default: the cluster's server_version)
#   CSI_DRIVER_VERSION, CSI_REGISTRAR_VERSION   SPIFFE CSI driver and kubelet registrar tags
#   WITH_CSI=0        omit the CSI driver (consumers then need hostPath and a privileged namespace)
set -euo pipefail
CSI_DRIVER_VERSION="${CSI_DRIVER_VERSION:-0.2.13}"
CSI_REGISTRAR_VERSION="${CSI_REGISTRAR_VERSION:-v2.18.0}"
WITH_CSI="${WITH_CSI:-1}"

here="$(cd "$(dirname "$0")/.." && pwd)"
: "${PROXY_ADDR:?set PROXY_ADDR (host:port)}"
: "${TOKEN_NAME:?set TOKEN_NAME}"
TELEPORT_CLUSTER="${TELEPORT_CLUSTER:-${PROXY_ADDR%%:*}}"
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
