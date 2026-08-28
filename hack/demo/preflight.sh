#!/usr/bin/env bash
# Preflight for the H200 fleet demo: assert every precondition BEFORE touching
# the shared lab VM in any way that matters to the deployment.
#
# NOT strictly read-only: the etcd-suitability check below writes a throwaway
# 4MB file under /var/tmp on the VM (1000x 4KiB oflag=dsync writes, to measure
# fsync latency for etcd's WAL) and removes it immediately via trap. There is
# no way to measure real fsync latency without performing a real fsync write,
# and fio is not installed there (installing it would itself be a mutation).
# Every other check remains pure observation: nvidia-smi, nproc, sudo -n, and
# a throwaway local TCP forward that never touches the VM's filesystem.
#
# shellcheck disable=SC2015  # `check && pass || fail`: pass always returns 0,
#                            # so fail can never spuriously run on success.
# shellcheck disable=SC1091  # lib.sh is resolved at runtime relative to $0;
#                            # shellcheck can't follow the dynamic path.
# shellcheck disable=SC2016  # the rsh payload is deliberately single-quoted
#                            # so its $(...) expand on the REMOTE shell, not
#                            # locally before it ever reaches ssh.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
RC=0

# lib.sh's public helpers stop at pass/fail (a check either satisfies the
# precondition or blocks the plan); this script alone also needs a middle
# state that still counts as a pass, so it defines its own local warn().
warn() { printf 'WARN  %s\n' "$1"; }

log "local tooling"
for t in ssh autossh docker kind kubectl helm; do
  command -v "$t" >/dev/null && pass "$t present" || fail "$t missing"
done

log "remote reachability and shape"
info=$(rsh 'echo "gpus=$(nvidia-smi -L 2>/dev/null | wc -l)"; echo "driver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)"; echo "cpus=$(nproc)"; echo "k0s=$(command -v k0s || echo none)"; echo "sudo=$(sudo -n true 2>/dev/null && echo yes || echo no)"' 2>/dev/null || true)
[ -n "$info" ] && pass "ssh works" || fail "cannot reach the VM"
has "gpus=2" "$info"  && pass "2 GPUs visible"        || fail "expected 2 GPUs: $info"
has "sudo=yes" "$info" && pass "passwordless sudo"     || fail "sudo unavailable"
has "driver=6" "$info" && pass "host NVIDIA driver present" || fail "no host driver: $info"

log "etcd suitability (disk fsync latency)"
# k0s defaults to etcd as its datastore, and etcd's WAL is fsync-heavy: every
# write calls fsync before it's acknowledged. /var/lib (where the WAL will
# live) is on the same filesystem as / (/dev/vda1), which reports ROTA=1 from
# inside the guest -- likely a virtio abstraction over an underlying SSD, but
# unproven from in here, so measure rather than assume. fio isn't installed
# and installing it would itself be a mutation, so this is a shell-only
# probe: 1000x 4KiB synchronous writes via `dd ... oflag=dsync`, timed with
# the VM's own clock. The temp file lives under /var/tmp and is removed by a
# trap so it's gone even if dd fails partway through.
#
# Gate follows etcd's own guidance (p99 fsync < 10ms): a dd AVERAGE is
# coarser than a p99, so a box that fails the average will certainly fail
# the p99 gate too. 10-25ms/op is a soft warn, not a hard fail: etcd may
# stall under write bursts but the demo can likely still run; kine is the
# documented fallback datastore if that turns out not to be true.
ns=$(rsh '
  set -e
  f=/var/tmp/etcd-fsync-probe.$$
  trap "rm -f \"$f\"" EXIT
  start=$(date +%s%N)
  dd if=/dev/zero of="$f" bs=4k count=1000 oflag=dsync 2>/dev/null
  end=$(date +%s%N)
  echo $((end - start))
' 2>/dev/null || true)
if [ -n "$ns" ]; then
  result=$(awk -v ns="$ns" 'BEGIN {
      ms = (ns / 1000000) / 1000
      v  = (ms < 10) ? "ok" : (ms < 25) ? "warn" : "fail"
      printf "%.2f %s", ms, v
    }')
  ms_per_op="${result% *}"
  verdict="${result#* }"
  case "$verdict" in
    ok)   pass "etcd fsync latency ${ms_per_op} ms/op (< 10ms, default etcd datastore should be fine)" ;;
    warn) warn "etcd fsync latency ${ms_per_op} ms/op -- 10-25ms/op: etcd may stall under write bursts during the demo; kine is the fallback datastore" ;;
    *)    fail "etcd fsync latency ${ms_per_op} ms/op -- too slow for etcd's WAL fsync (guidance: p99 < 10ms); switch to kine" ;;
  esac
else
  fail "could not measure disk fsync latency on the VM"
fi

log "tcp forwarding through warden"
pkill -f "${TUNNEL_PORT}:127.0.0.1:22" 2>/dev/null || true
if ssh -o BatchMode=yes -o ExitOnForwardFailure=yes -f -N \
       -L 19222:127.0.0.1:22 "$REMOTE" -p "$SSH_PORT" 2>/dev/null; then
  sleep 2
  nc -z 127.0.0.1 19222 && pass "TCP forwarding permitted" || fail "forward opened but dead"
  pkill -f "19222:127.0.0.1:22" 2>/dev/null || true
else
  fail "warden refuses TCP forwarding — the tunnel topology is not viable"
fi

log "docker can reach the host loopback (kind -> tunnel path)"
# The adoption kubeconfig will point kind's containers at host.docker.internal.
# Prove that name resolves from inside a container on this Docker before
# relying on it. If this fails, the fallback is the kind bridge gateway IP.
if out=$(docker run --rm alpine:3.20 getent hosts host.docker.internal 2>&1); then
  pass "host.docker.internal resolves in containers ($out)"
else
  fail "host.docker.internal does not resolve — use the kind bridge gateway IP instead (spec §4 A2 fallback)"
fi

echo
[ "$RC" -eq 0 ] && echo "PREFLIGHT PASSED" || echo "PREFLIGHT FAILED" >&2
exit "$RC"
