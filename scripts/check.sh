#!/usr/bin/env bash
# Health check for one cluster's issuer. Run after install, and before a demo.
#
#   scripts/check.sh k8s-prod        # checks the CURRENT kubectl context; k8s-prod is the bot name
#
# Prints one line per check. Exit code is non-zero if anything failed.
set -uo pipefail

bot="${1:?usage: check.sh <bot-name>}"
fail=0
ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fail=1; }

echo "issuer check — kubectl context $(kubectl config current-context 2>/dev/null), bot ${bot}"

# DaemonSets: every node should run tbot and the CSI driver.
for ds in tbot spiffe-csi-driver; do
  read -r desired ready image < <(kubectl -n teleport-wi get ds "$ds" \
      -o jsonpath='{.status.desiredNumberScheduled} {.status.numberReady} {.spec.template.spec.containers[0].image}' 2>/dev/null)
  if [ -z "${desired:-}" ]; then
    bad "DaemonSet teleport-wi/${ds} not found"
  elif [ "$desired" = "$ready" ] && [ "$ready" != "0" ]; then
    ok "DaemonSet ${ds}: ${ready}/${desired} ready (${image##*/})"
  else
    bad "DaemonSet ${ds}: ${ready:-0}/${desired} ready"
  fi
done

# The CSI driver must be registered for csi volumes to mount.
if kubectl get csidriver csi.spiffe.io >/dev/null 2>&1; then
  ok "CSIDriver csi.spiffe.io registered"
else
  bad "CSIDriver csi.spiffe.io missing (rendered with WITH_CSI=0? consumers then need hostPath)"
fi

# tbot's readiness probe is /readyz, which is green only when its services (the
# Workload API included) are healthy — so "ready" above already proves the
# socket is being served. Count recent issuances for a feel of activity.
issued=$(kubectl -n teleport-wi logs ds/tbot --all-pods --since=1h 2>/dev/null | grep -c '"Issued Workload Identity Credential"')
echo "  info  ${issued:-0} credential(s) issued in the last hour (one pod's log if --all-pods is unsupported)"

# Teleport side: the bot has healthy instances, and the token still matches the cluster.
if command -v tctl >/dev/null; then
  n=$(tctl bots instances ls 2>/dev/null | grep -c "^${bot}/")
  if [ "${n:-0}" -gt 0 ]; then ok "bot ${bot}: ${n} healthy instance(s)"; else bad "bot ${bot}: no instances in tctl bots instances ls"; fi
  if "$(dirname "$0")/jwks.sh" --check "${bot}-issuer" >/dev/null 2>&1; then
    ok "token ${bot}-issuer pins this cluster's current signing key(s)"
  else
    bad "token ${bot}-issuer does not match the cluster's JWKS — scripts/make-token.sh ${bot} | tctl create --force -f -"
  fi
else
  echo "  skip  tctl not on PATH; bot and token checks skipped"
fi

exit "$fail"
