#!/usr/bin/env bash
# Install single-node k0s on the remote H200 box, shaped for adoption by a
# k0rdent mothership reached through an SSH tunnel.
#
# Three things are configured at INSTALL time rather than patched afterwards:
#
#  1. API SANs including host.docker.internal — the adoption kubeconfig points
#     there, so without the SAN every client would need
#     insecure-skip-tls-verify. k0s also emits a trailing-dot SAN
#     (kubernetes.default.svc.cluster.local.) that FIPS-only clients such as
#     the flux-operator kcm runs reject as malformed; Task 4 repairs that.
#  2. Control-plane taint removed — a single node must run workloads.
#  3. A default StorageClass — k0s ships none and kube-prometheus-stack
#     (part of every AICR recipe) wants PVCs.
#
# spec.storage is deliberately left out of k0s.yaml below, which yields k0s's
# default datastore, etcd. The VM's disk was probed at 1.03 ms/op synchronous
# write latency (see preflight.sh), comfortably inside etcd's needs, and this
# is chosen for production fidelity over a kine/SQLite shortcut.
#
# shellcheck disable=SC2015  # `check && pass || fail`: pass always returns 0,
#                            # so fail can never spuriously run on success.
# shellcheck disable=SC1091  # lib.sh is resolved at runtime relative to $0;
#                            # shellcheck can't follow the dynamic path.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
RC=0

log "existing cluster?"
cur=$(rsh 'command -v k0s >/dev/null && sudo k0s status 2>/dev/null || echo none' || true)
if has "Version" "$cur"; then
  echo "k0s already running; skipping install. Re-run teardown.sh first for a clean slate."
else
  log "installing k0s ${K0S_VERSION}"
  rsh "curl -sSLf https://get.k0s.sh | sudo K0S_VERSION=${K0S_VERSION} sh" >/dev/null
  # Config with tunnel-aware SANs. host.docker.internal is what kind's
  # containers will dial; 127.0.0.1 is the tunnel's local end.
  hostname=$(rsh 'hostname')
  rsh "sudo mkdir -p /etc/k0s && sudo tee /etc/k0s/k0s.yaml >/dev/null <<'EOF'
apiVersion: k0s.k0sproject.io/v1beta1
kind: ClusterConfig
metadata:
  name: k0s
spec:
  api:
    sans:
      - host.docker.internal
      - 127.0.0.1
      - localhost
      - ${hostname}
  network:
    # Must not overlap the outer KubeVirt cluster (pod net 10.244.0.0/22,
    # CoreDNS 10.96.0.10). k0s defaults collide with both.
    podCIDR: ${POD_CIDR}
    serviceCIDR: ${SERVICE_CIDR}
EOF"
  rsh "sudo k0s install controller --enable-worker -c /etc/k0s/k0s.yaml && sudo k0s start"
fi

log "waiting for the API"
for _ in $(seq 1 60); do
  st=$(rsh 'sudo k0s kubectl get --raw=/readyz 2>/dev/null || true' || true)
  has "ok" "$st" && break
  sleep 5
done
has "ok" "$st" && pass "API is ready" || { fail "API never became ready"; exit 1; }

log "allow workloads on the single node"
# `taint ... - 2>/dev/null || true` ALWAYS succeeds, so asserting on it is a
# tautology: on a fresh install the node may not have registered yet, the
# removal silently fails, and we would report success while local-path (and
# every later workload) sits Pending on an untolerated taint. Retry until the
# node exists, then VERIFY the taint is actually gone.
for _ in $(seq 1 24); do
  rsh 'sudo k0s kubectl taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule- >/dev/null 2>&1 || true'
  t=$(rsh 'sudo k0s kubectl get node -o jsonpath="{.items[*].spec.taints}" 2>/dev/null' || true)
  case "$t" in *control-plane*) sleep 5 ;; *) break ;; esac
done
case "$t" in
  *control-plane*) fail "control-plane taint still present: $t" ;;
  *)               pass "control-plane taint removed (verified absent)" ;;
esac

log "default StorageClass"
# Table form (not `-o name`) so the "(default)" marker is visible here too --
# a class can already exist (hand-installed k0s, or a prior run of this
# script) without being marked default, and that's a distinct case from no
# class at all: kube-prometheus-stack (every AICR recipe) requests PVCs
# without naming a class, so an undefaulted class leaves those Pending
# forever, same as having none.
sc=$(rsh 'sudo k0s kubectl get sc 2>/dev/null || true' || true)
if [ -z "$sc" ]; then
  log "no StorageClass found; installing local-path-provisioner"
  rsh 'sudo k0s kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.31/deploy/local-path-storage.yaml' >/dev/null
  rsh 'sudo k0s kubectl -n local-path-storage rollout status deploy/local-path-provisioner --timeout=180s' >/dev/null
  rsh 'sudo k0s kubectl patch storageclass local-path -p "{\"metadata\":{\"annotations\":{\"storageclass.kubernetes.io/is-default-class\":\"true\"}}}"' >/dev/null
elif ! has "(default)" "$sc"; then
  log "StorageClass exists but none is default; marking local-path default"
  rsh 'sudo k0s kubectl patch storageclass local-path -p "{\"metadata\":{\"annotations\":{\"storageclass.kubernetes.io/is-default-class\":\"true\"}}}"' >/dev/null
fi
sc=$(rsh 'sudo k0s kubectl get sc 2>/dev/null || true' || true)
has "(default)" "$sc" && pass "default StorageClass present" || fail "no default StorageClass: $sc"

log "confirm the k0s containerd paths the pack targets"
# NOT `ls -d ... 2>&1`: ls's own "No such file or directory" error text
# echoes the path back, so a substring match against that captured output
# is true whether the path exists or not -- a tautology that always passes.
# test -S/-d give a real predicate; matching on a plain yes/no token (rather
# than on the path string) keeps the assertion falsifiable.
sock=$(rsh 'test -S /run/k0s/containerd.sock && echo yes || echo no' || true)
dir=$(rsh 'test -d /etc/k0s/containerd.d && echo yes || echo no' || true)
has "yes" "$sock" && pass "containerd socket at /run/k0s/containerd.sock" \
  || fail "socket path differs — the pack's toolkit.env needs updating (test -S: $sock)"
has "yes" "$dir" && pass "drop-in dir /etc/k0s/containerd.d exists" \
  || echo "note: /etc/k0s/containerd.d absent; the toolkit creates it — verify in Plan C"

log "fetch kubeconfig for tunnel use"
rsh 'sudo k0s kubeconfig admin' > "$STATE/kcfg_child_local"
sed -i.bak "s#server:.*#server: https://127.0.0.1:${TUNNEL_PORT}#" "$STATE/kcfg_child_local"
rm -f "$STATE/kcfg_child_local.bak"; chmod 0600 "$STATE/kcfg_child_local"
pass "wrote $STATE/kcfg_child_local"

echo
[ "$RC" -eq 0 ] && echo "K0S READY" || echo "K0S SETUP HAD FAILURES" >&2
exit "$RC"
