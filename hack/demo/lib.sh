#!/usr/bin/env bash
# Shared helpers for the H200 fleet demo scripts.
#
# Sourced, never executed. Centralises the one ssh target string so a change
# of lab host is a one-line edit, and keeps every generated kubeconfig under
# .state/ (gitignored) so nothing secret can be committed by accident.
#
# `has` matches against a CAPTURED string rather than piping into `grep -q`:
# under `set -o pipefail` grep -q exits on its first match, the producer dies
# of SIGPIPE, and a SUCCESSFUL match reports failure.
#
# shellcheck disable=SC2034  # RC looks unused from inside this file: it's
# defined by each script that sources lib.sh (e.g. preflight.sh's `RC=0`)
# and only ever assigned here, in fail(), for that caller to read afterward.

REMOTE="${REMOTE:-sbhardwaj@mirantis.com:nvl3-gpuvm1@warden.mircloud.miralabs.dev}"
SSH_PORT="${SSH_PORT:-22}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="${STATE:-$HERE/.state}"
mkdir -p "$STATE"

K0S_VERSION="${K0S_VERSION:-v1.36.3+k0s.0}"
KCM_VERSION="${KCM_VERSION:-1.11.0}"
MGMT_CLUSTER="${MGMT_CLUSTER:-aicr-mothership}"
TUNNEL_PORT="${TUNNEL_PORT:-6443}"

# Child cluster CIDRs. NOT k0s's defaults (10.244.0.0/16 + 10.96.0.0/12) on
# purpose: this VM is a KubeVirt guest whose own network IS the outer
# cluster's pod network (10.244.0.0/22, VM 10.244.0.49) and whose DNS
# (10.96.0.10) is the outer cluster's CoreDNS. The defaults collide with both
# — k0s then hijacks traffic to the host's real resolver, and inner pod IPs
# land inside the outer pod network, making pod egress intermittent.
# 172.16/12 has zero routes on this VM (verified 2026-08-28).
# See docs/design/2026-08-28-child-cidr-rebuild.md.
POD_CIDR="${POD_CIDR:-172.21.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-172.20.0.0/16}"

log()  { printf '\n== %s ==\n' "$1"; }
pass() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1" >&2; RC=1; }
has()  { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

# rsh "<command>" — run a command on the VM, non-interactive.
rsh() { ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new \
             "$REMOTE" -p "$SSH_PORT" "$@"; }
