#!/usr/bin/env bash
# Keep a forward from the laptop to the child's API server, and produce the
# kubeconfig the mothership will use.
#
# Two different kubeconfigs exist by necessity: the laptop dials 127.0.0.1
# (the tunnel's local end) while kind's CONTAINERS must dial
# host.docker.internal (the laptop, from inside Docker). Same cluster, same
# CA, different server field. Both names are in the API cert's SANs.
#
# autossh, not plain ssh: a dropped forward mid-demo silently stops all
# service delivery, and the failure looks like "Sveltos is broken".
#
# shellcheck disable=SC2015  # `check && pass || fail`: pass always returns 0,
#                            # so fail can never spuriously run on success.
# shellcheck disable=SC1091  # lib.sh is resolved at runtime relative to $0;
#                            # shellcheck can't follow the dynamic path.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
RC=0
ACTION="${1:-up}"

case "$ACTION" in
  down)
    pkill -f "${TUNNEL_PORT}:127.0.0.1:6443" 2>/dev/null || true
    echo "tunnel down"; exit 0 ;;
  up) ;;
  *) echo "usage: tunnel.sh [up|down]" >&2; exit 2 ;;
esac

log "starting tunnel"
if pgrep -f "${TUNNEL_PORT}:127.0.0.1:6443" >/dev/null; then
  pass "tunnel already running"
else
  AUTOSSH_GATETIME=0 autossh -M 0 -f -N \
    -o BatchMode=yes -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
    -L "${TUNNEL_PORT}:127.0.0.1:6443" "$REMOTE" -p "$SSH_PORT"
  sleep 3
  pgrep -f "${TUNNEL_PORT}:127.0.0.1:6443" >/dev/null && pass "tunnel up" || { fail "tunnel failed to start"; exit 1; }
fi

log "API reachable from the laptop"
if out=$(KUBECONFIG="$STATE/kcfg_child_local" kubectl get --raw=/readyz 2>&1); then
  has "ok" "$out" && pass "laptop -> child API ok" || fail "unexpected readyz: $out"
else
  fail "laptop cannot reach the child API through the tunnel: $out"
fi

log "write the kind-facing kubeconfig"
sed "s#server:.*#server: https://host.docker.internal:${TUNNEL_PORT}#" \
  "$STATE/kcfg_child_local" > "$STATE/kcfg_child_kind"
chmod 0600 "$STATE/kcfg_child_kind"
pass "wrote $STATE/kcfg_child_kind"

log "extract the CA to a real file (containers cannot read a /dev/fd path)"
# The CA must land in an actual file that can be bind-mounted. An earlier
# draft passed it via process substitution — `--cacert <(...)` — which yields
# a /dev/fd/N path valid only in the HOST shell; inside the container it
# refers to nothing, so curl silently validated against no CA at all.
KUBECONFIG="$STATE/kcfg_child_kind" kubectl config view --raw \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' \
  | base64 -d > "$STATE/child-ca.crt"
[ -s "$STATE/child-ca.crt" ] && pass "wrote $STATE/child-ca.crt" || { fail "empty CA"; exit 1; }

log "API reachable from a container with VALID TLS"
# Early signal that host.docker.internal resolves from Docker AND that the
# serving cert really carries that SAN (curl without -k proves it; -k would
# prove nothing). This runs on the DEFAULT bridge — the definitive check, on
# the kind network kcm's controllers actually use, runs in mothership.sh
# after the kind cluster exists. `--network host` is deliberately NOT used:
# on Docker Desktop for macOS it does not behave as it does on Linux.
if out=$(docker run --rm -v "$STATE/child-ca.crt:/ca.crt:ro" curlimages/curl:8.10.1 \
          -sS --cacert /ca.crt \
          "https://host.docker.internal:${TUNNEL_PORT}/readyz" 2>&1); then
  # k0s hardcodes --anonymous-auth=false on the API server (confirmed on the
  # VM's running kube-apiserver process args; it is not set in our k0s.yaml,
  # so it's k0s's own default, unlike vanilla kubeadm which permits anonymous
  # GET on /readyz). This curl carries no client credentials, so a healthy
  # cluster answers "401 Unauthorized" here instead of "ok". That response
  # is still definitive proof of valid TLS: it is a well-formed Kubernetes
  # API JSON body, reachable ONLY after curl's cert-hostname verification
  # already succeeded — a real SAN/CA mismatch fails at the TLS layer with a
  # curl error (exit != 0, landing in the `else` branch below) and never
  # reaches the API to get authenticated. Accepting it is not the insecure
  # skip this check exists to forbid; it is recognizing that verification
  # already passed.
  if has "ok" "$out"; then
    pass "container -> child API with valid TLS"
  elif has "Unauthorized" "$out"; then
    pass "container -> child API with valid TLS (401 from k0s's anonymous-auth=false default; TLS itself verified)"
  else
    fail "readyz from container: $out"
  fi
else
  fail "container cannot reach host.docker.internal:${TUNNEL_PORT} with valid TLS: $out"
fi

echo
[ "$RC" -eq 0 ] && echo "TUNNEL READY" || echo "TUNNEL NOT READY" >&2
exit "$RC"
