#!/usr/bin/env bash
# Regenerate the k0s kube-apiserver serving cert without the trailing-dot SAN
# "kubernetes.default.svc.cluster.local." which FIPS-only clients (the
# flux-operator kcm runs) reject as malformed. Signed by the existing CA, so
# every existing kubeconfig keeps working.
#
# SSH counterpart of k0rdent-catalog's scripts/fix_adopted_cert_sans.sh, which
# assumes the cluster is a local docker container.
#
# shellcheck disable=SC1091  # lib.sh is resolved at runtime relative to $0;
#                            # shellcheck can't follow the dynamic path.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

PKI=/var/lib/k0s/pki
sans=$(rsh "sudo openssl x509 -in $PKI/server.crt -noout -text" \
        | awk '/Subject Alternative Name/{getline; print}' \
        | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

if ! printf '%s\n' "$sans" | awk '/^DNS:.*\.$/{found=1} END{exit !found}'; then
  echo "No trailing-dot SAN present; nothing to do."
  exit 0
fi

cnf=$(
  printf '[req]\ndistinguished_name = dn\nreq_extensions = v3\nprompt = no\n[dn]\nO = kubernetes\nCN = kube-apiserver\n[v3]\nkeyUsage = critical, digitalSignature, keyEncipherment\nextendedKeyUsage = serverAuth\nsubjectAltName = @alt\n[alt]\n'
  d=0; i=0
  while read -r e; do
    case "$e" in
      DNS:*.) ;;                                   # drop the malformed FQDN
      DNS:*)  d=$((d+1)); printf 'DNS.%d = %s\n' "$d" "${e#DNS:}" ;;
      "IP Address:"*) i=$((i+1)); printf 'IP.%d = %s\n' "$i" "${e#IP Address:}" ;;
    esac
  done <<<"$sans"
)

rsh "sudo tee /tmp/san.cnf >/dev/null" <<<"$cnf"
# -x, not -f: pkill -f matches the FULL COMMAND LINE of every process on
# the box, including this very ssh session's own shell, whose argv (the
# remote command string below) contains the literal substring
# "kube-apiserver" — pkill excludes only its own PID, never its parent, so
# -f here would SIGTERM the shell running it and drop the ssh connection
# (observed: exit 255 on a run where the fix itself fully succeeded). -x
# matches by exact process NAME instead (comm, e.g. "bash" for this shell
# vs "kube-apiserver" for the real binary at /var/lib/k0s/bin/kube-apiserver),
# so it cannot self-match no matter what text appears in argv. Verified
# live: `pgrep -af kube-apiserver` matches the invoking shell PID as well
# as the apiserver PID, while `pgrep -x kube-apiserver` matches only the
# apiserver PID.
rsh "cd /tmp && sudo openssl req -new -key $PKI/server.key -out /tmp/s.csr -config /tmp/san.cnf \
  && sudo openssl x509 -req -in /tmp/s.csr -CA $PKI/ca.crt -CAkey $PKI/ca.key -CAcreateserial \
       -out /tmp/s.crt -days 365 -extfile /tmp/san.cnf -extensions v3 \
  && sudo cp /tmp/s.crt $PKI/server.crt && sudo chmod 0644 $PKI/server.crt \
  && sudo pkill -x kube-apiserver || true"

echo "Waiting for the API to come back..."
for _ in $(seq 1 60); do
  st=$(rsh 'sudo k0s kubectl get --raw=/readyz 2>/dev/null || true' || true)
  case "$st" in *ok*) echo "apiserver back up with cleaned SANs."; exit 0 ;; esac
  sleep 3
done
echo "apiserver did not come back" >&2; exit 1
