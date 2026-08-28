#!/usr/bin/env bash
# Prove service delivery reaches the adopted child with something trivial,
# BEFORE the AICR stack is involved.
#
# Why bother: the AICR install takes many minutes and touches drivers, the
# container runtime and a dozen charts. If delivery itself is broken, that run
# fails in a way that looks like a GPU problem and costs an hour to diagnose.
# A tiny chart isolates the plumbing in about a minute.
#
# shellcheck disable=SC2015  # `check && pass || fail`: pass always returns 0,
#                            # so fail can never spuriously run on success.
# shellcheck disable=SC1091  # lib.sh is resolved at runtime relative to $0;
#                            # shellcheck can't follow the dynamic path.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
RC=0
export KUBECONFIG="$STATE/kcfg_mgmt"

log "register a trivial ServiceTemplate via kgst"
helm upgrade --install cert-manager-st oci://ghcr.io/k0rdent/catalog/charts/kgst \
  --set "chart=cert-manager:1.16.2" -n kcm-system --wait --timeout 5m >/dev/null
for _ in $(seq 1 30); do
  v=$(kubectl get servicetemplate -n kcm-system -o jsonpath='{range .items[*]}{.metadata.name}={.status.valid}{"\n"}{end}' 2>/dev/null || true)
  has "=true" "$v" && break
  sleep 5
done
has "=true" "$v" && pass "a ServiceTemplate reports valid=true" || fail "no valid ServiceTemplate: $v"

log "deliver it to the child by label"
st=$(kubectl get servicetemplate -n kcm-system -o name | sed 's#.*/##' | awk '/cert-manager/{print; exit}')
kubectl apply -f - <<EOF
apiVersion: k0rdent.mirantis.com/v1beta1
kind: MultiClusterService
metadata:
  name: delivery-gate
spec:
  clusterSelector:
    matchLabels:
      group: gpu-fleet
  serviceSpec:
    services:
      - template: $st
        name: cert-manager
        namespace: cert-manager-gate
EOF

log "did it land ON THE CHILD?"
for _ in $(seq 1 60); do
  pods=$(KUBECONFIG="$STATE/kcfg_child_local" kubectl get pods -n cert-manager-gate -o name 2>/dev/null || true)
  [ -n "$pods" ] && break
  sleep 10
done
[ -n "$pods" ] && pass "pods present on the child: $(printf '%s' "$pods" | tr '\n' ' ')" \
  || { fail "nothing landed on the child within 10m"
       kubectl get multiclusterservice delivery-gate -o yaml | tail -30
       kubectl get clustersummary -A 2>/dev/null | tail -10 || true; }

log "cleanup the gate"
kubectl delete multiclusterservice delivery-gate --ignore-not-found >/dev/null
helm uninstall cert-manager-st -n kcm-system >/dev/null 2>&1 || true

echo
[ "$RC" -eq 0 ] && echo "DELIVERY GATE PASSED — Plan C may proceed" || echo "DELIVERY GATE FAILED" >&2
exit "$RC"
