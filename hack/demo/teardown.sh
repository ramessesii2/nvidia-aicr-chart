#!/usr/bin/env bash
# Undo everything the demo created. Written before the installer on purpose.
#
# shellcheck disable=SC1091  # lib.sh is resolved at runtime relative to $0;
#                            # shellcheck can't follow the dynamic path.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

echo "Stopping tunnel..."
pkill -f "${TUNNEL_PORT}:127.0.0.1:6443" 2>/dev/null || true

echo "Deleting the mothership kind cluster..."
kind delete cluster --name "$MGMT_CLUSTER" 2>/dev/null || true

echo "Resetting k0s on the VM (removes the cluster and its data)..."
rsh 'sudo k0s stop 2>/dev/null || true; sudo k0s reset --force 2>/dev/null || true; echo "k0s reset done"'

echo "Clearing local state..."
rm -rf "$STATE"
echo "Teardown complete."
