#!/usr/bin/env bash
# Stand up the local kind mothership (kcm) and adopt the remote H200 cluster.
#
# Adoption is credential-based: kcm gets a kubeconfig for a cluster it did not
# provision, wrapped in a Credential, and a ClusterDeployment using the
# adopted-cluster template. The kubeconfig's server must be an address kcm's
# CONTAINERS can reach, hence the host.docker.internal variant from tunnel.sh.
#
# shellcheck disable=SC2015  # `check && pass || fail`: pass always returns 0,
#                            # so fail can never spuriously run on success.
# shellcheck disable=SC1091  # lib.sh is resolved at runtime relative to $0;
#                            # shellcheck can't follow the dynamic path.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
RC=0
export KUBECONFIG="$STATE/kcfg_mgmt"

log "kind cluster ${MGMT_CLUSTER}"
if kind get clusters 2>/dev/null | awk -v c="$MGMT_CLUSTER" '$0==c{f=1} END{exit !f}'; then
  pass "cluster exists"
else
  kind create cluster --name "$MGMT_CLUSTER" --image kindest/node:v1.34.0
fi
kind get kubeconfig --name "$MGMT_CLUSTER" > "$STATE/kcfg_mgmt"
chmod 0600 "$STATE/kcfg_mgmt"

log "install kcm ${KCM_VERSION}"
if helm status kcm -n kcm-system >/dev/null 2>&1; then
  pass "kcm already installed"
else
  kubectl create namespace projectsveltos --dry-run=client -o yaml | kubectl apply -f -
  helm install kcm oci://ghcr.io/k0rdent/kcm/charts/kcm \
    --version "$KCM_VERSION" -n kcm-system --create-namespace --wait --timeout 15m
fi
kubectl wait --for=condition=Ready management.k0rdent.mirantis.com/kcm --timeout=15m
pass "kcm Ready"

log "child API reachable FROM THE KIND NETWORK with valid TLS"
# The definitive reachability check, and the reason it lives here rather than
# in tunnel.sh: kcm's controllers dial the child from inside a container on
# kind's own network, and that network does not exist until the cluster above
# is created. tunnel.sh proves the path from the default bridge as early
# signal; this proves the path kcm will actually take. If this fails, the
# adoption below would fail later and far more confusingly.
knet=$(docker inspect "${MGMT_CLUSTER}-control-plane" \
        -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}')
if out=$(docker run --rm --network "$knet" -v "$STATE/child-ca.crt:/ca.crt:ro" \
          curlimages/curl:8.10.1 -sS --cacert /ca.crt \
          "https://host.docker.internal:${TUNNEL_PORT}/readyz" 2>&1); then
  # k0s runs with --anonymous-auth=false (see tunnel.sh), so this
  # unauthenticated curl gets a well-formed 401 JSON body instead of "ok" on
  # a healthy cluster. That body is only reachable after TLS verification
  # already succeeded, so it is equally definitive proof as "ok" — checking
  # for "ok" alone would spuriously fail this gate on every healthy run.
  if has "ok" "$out"; then
    pass "kind network -> child API, TLS valid"
  elif has "Unauthorized" "$out"; then
    pass "kind network -> child API, TLS valid (401 from k0s's anonymous-auth=false default; TLS itself verified)"
  else
    fail "readyz from the kind network: $out"
  fi
else
  fail "kind network cannot reach the child API: $out"
  echo "  (kind net: $knet — if host.docker.internal is unresolvable here, fall back to the"
  echo "   bridge gateway IP and add it to the k0s SANs; see the spec's §4 A2 fallback)"
fi

log "adoption credential"
kubectl create secret generic h200-child-kubeconfig -n kcm-system \
  --from-file=value="$STATE/kcfg_child_kind" \
  --dry-run=client -o yaml | kubectl apply -f -

tmpl=$(kubectl get clustertemplate -n kcm-system -o name 2>/dev/null \
       | sed 's#.*/##' | awk '/^adopted-cluster/{print; exit}')
[ -n "$tmpl" ] && pass "adopted template: $tmpl" || { fail "no adopted-cluster ClusterTemplate found"; exit 1; }

kubectl apply -f - <<EOF
apiVersion: k0rdent.mirantis.com/v1beta1
kind: Credential
metadata:
  name: h200-child-cred
  namespace: kcm-system
spec:
  identityRef:
    apiVersion: v1
    kind: Secret
    name: h200-child-kubeconfig
    namespace: kcm-system
---
apiVersion: k0rdent.mirantis.com/v1beta1
kind: ClusterDeployment
metadata:
  name: h200-child
  namespace: kcm-system
  labels:
    group: gpu-fleet
spec:
  template: $tmpl
  credential: h200-child-cred
  # kcm 1.11's mutation.clusterdeployment.k0rdent.mirantis.com webhook
  # defaults dryRun to true when the field is omitted (confirmed: no CRD
  # schema default, only the webhook). A dry-run ClusterDeployment only
  # validates the template — it never creates the underlying CAPI Cluster,
  # so Sveltos has nothing to register and h200-child never shows up as a
  # SveltosCluster. Must be explicit here to actually adopt anything.
  dryRun: false
EOF

# The webhook forces dryRun=true at CREATE time when the Credential is not yet
# Ready -- and the Credential and ClusterDeployment are applied together above,
# so the CD is admitted before the Credential validates. The field then stays
# true even after the Credential goes Ready, because nothing re-applies it.
# Result: Ready=True, provisions nothing, no SveltosCluster. Assert and repair.
log "assert the ClusterDeployment is NOT a dry run"
for _ in $(seq 1 12); do
  dr=$(kubectl get clusterdeployment h200-child -n kcm-system \
        -o jsonpath='{.spec.dryRun}' 2>/dev/null || true)
  [ "$dr" = "false" ] && break
  kubectl patch clusterdeployment h200-child -n kcm-system \
    --type=merge -p '{"spec":{"dryRun":false}}' >/dev/null 2>&1 || true
  sleep 5
done
[ "$dr" = "false" ] && pass "dryRun=false (adoption will actually provision)" \
  || fail "dryRun is '$dr' -- the CD would report Ready while provisioning nothing"

log "wait for the ClusterDeployment"
for _ in $(seq 1 60); do
  st=$(kubectl get clusterdeployment h200-child -n kcm-system \
        -o jsonpath='{range .status.conditions[?(@.status=="True")]}{.type} {end}' 2>/dev/null || true)
  has "Ready" "$st" && break
  sleep 10
done
has "Ready" "$st" && pass "ClusterDeployment h200-child Ready" || {
  fail "not Ready; conditions: $st"
  kubectl describe clusterdeployment h200-child -n kcm-system | tail -30
}

log "Sveltos sees the cluster"
sc=$(kubectl get sveltoscluster -A 2>/dev/null || true)
has "h200-child" "$sc" && pass "SveltosCluster registered" || fail "no SveltosCluster for h200-child: $sc"

echo
[ "$RC" -eq 0 ] && echo "MOTHERSHIP READY" || echo "MOTHERSHIP SETUP HAD FAILURES" >&2
exit "$RC"
