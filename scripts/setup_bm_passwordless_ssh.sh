#!/usr/bin/env bash
set -euo pipefail

# Run from head node home directory.
# Purpose: use the same private key you use to SSH to the head (copied to head as bootstrap key)
# to log into BM nodes, then install head's ~/.ssh/id_ed25519.pub for passwordless BM access.

BOOTSTRAP_KEY="${BOOTSTRAP_KEY:-$HOME/.ssh/head_login_key}"
TARGET_USER="${TARGET_USER:-cloud-user}"
ALT_USERS="opc ec2-user"
IDENTITY_KEY="$HOME/.ssh/id_ed25519"
IDENTITY_PUB="$HOME/.ssh/id_ed25519.pub"

# Default BM list from latest successful Phoenix apply; override with BM_IPS env var.
BM_IPS_DEFAULT="172.16.6.214 172.16.7.211 172.16.5.157 172.16.7.29"
BM_IPS="${BM_IPS:-$BM_IPS_DEFAULT}"
DO_HOSTS_UPDATE="${DO_HOSTS_UPDATE:-true}"

usage() {
  cat <<EOF
Usage:
  ./setup_bm_passwordless_ssh.sh
  BOOTSTRAP_KEY=~/.ssh/head_login_key BM_IPS="172.16.6.214 172.16.7.211" ./setup_bm_passwordless_ssh.sh

Environment variables:
  BOOTSTRAP_KEY   Private key copied from your local machine (default: ~/.ssh/head_login_key)
  BM_IPS          Space-separated BM private IP list
  TARGET_USER     Primary BM login user (default: cloud-user)
  DO_HOSTS_UPDATE Update /etc/hosts on head + BMs using discovered hostnames (default: true)
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ ! -f "$BOOTSTRAP_KEY" ]]; then
  echo "ERROR: Bootstrap key not found: $BOOTSTRAP_KEY"
  echo "Copy your local key to head first (see docs/HEAD-BM-SSH-README.md)."
  exit 1
fi

# Normalize accidental CRLF/private-key paste issues.
if grep -q $'\r' "$BOOTSTRAP_KEY"; then
  sed -i 's/\r$//' "$BOOTSTRAP_KEY"
fi
chmod 600 "$BOOTSTRAP_KEY"

if ! ssh-keygen -lf "$BOOTSTRAP_KEY" >/dev/null 2>&1; then
  echo "ERROR: $BOOTSTRAP_KEY is not a valid private key format."
  echo "Tip: re-copy with scp and avoid copy/paste into terminal."
  exit 1
fi

if [[ ! -f "$IDENTITY_KEY" || ! -f "$IDENTITY_PUB" ]]; then
  echo "Head id_ed25519 not found, generating one..."
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  ssh-keygen -t ed25519 -N '' -f "$IDENTITY_KEY"
fi

PUB_KEY_CONTENT="$(cat "$IDENTITY_PUB")"
if [[ -z "$PUB_KEY_CONTENT" ]]; then
  echo "ERROR: Empty public key at $IDENTITY_PUB"
  exit 1
fi

echo "Using bootstrap key: $BOOTSTRAP_KEY"
echo "Using identity key to install: $IDENTITY_PUB"
echo "BM IPs: $BM_IPS"

auth_ok=0
HOST_MAP_FILE="$(mktemp)"
trap 'rm -f "$HOST_MAP_FILE"' EXIT

for ip in $BM_IPS; do
  echo "===== $ip ====="

  success=0
  for u in "$TARGET_USER" $ALT_USERS; do
    echo "Trying user: $u"

    if ssh -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -i "$BOOTSTRAP_KEY" "$u@$ip" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && grep -qxF '$PUB_KEY_CONTENT' ~/.ssh/authorized_keys || echo '$PUB_KEY_CONTENT' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"; then
      echo "Installed pubkey for $u@$ip"

      host_short="$(ssh -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -i "$BOOTSTRAP_KEY" "$u@$ip" 'hostname -s' 2>/dev/null || true)"
      if [[ -z "$host_short" ]]; then
        host_short="bm-${ip//./-}"
      fi
      echo "$ip $host_short $u" >> "$HOST_MAP_FILE"
      echo "Mapped $ip -> $host_short (user=$u)"

      if ssh -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -i "$IDENTITY_KEY" "$u@$ip" 'hostname; whoami' >/dev/null 2>&1; then
        echo "Passwordless OK with $IDENTITY_KEY -> $u@$ip"
      else
        echo "WARNING: Could not verify id_ed25519 login for $u@$ip"
      fi

      success=1
      auth_ok=$((auth_ok + 1))
      break
    fi
  done

  if [[ "$success" -eq 0 ]]; then
    echo "FAILED: Could not access $ip with bootstrap key using users: $TARGET_USER $ALT_USERS"
  fi

done

if [[ "$DO_HOSTS_UPDATE" == "true" && -s "$HOST_MAP_FILE" ]]; then
  echo "Updating /etc/hosts on head and reachable BMs..."

  HOSTS_BLOCK_FILE="$(mktemp)"
  {
    echo "# BEGIN KOVE BM HOSTS"
    while read -r ip host _user; do
      echo "$ip $host"
    done < "$HOST_MAP_FILE"
    echo "# END KOVE BM HOSTS"
  } > "$HOSTS_BLOCK_FILE"

  HOSTS_BLOCK_B64="$(base64 -w0 "$HOSTS_BLOCK_FILE")"
  rm -f "$HOSTS_BLOCK_FILE"

  sudo bash -lc '
    set -euo pipefail
    tmp="$(mktemp)"
    cp /etc/hosts "$tmp"
    sed -i "/# BEGIN KOVE BM HOSTS/,/# END KOVE BM HOSTS/d" "$tmp"
    printf "%s" "'"$HOSTS_BLOCK_B64"'" | base64 -d >> "$tmp"
    printf "\n" >> "$tmp"
    cp "$tmp" /etc/hosts
    rm -f "$tmp"
  '
  echo "Updated /etc/hosts on head."

  while read -r ip _host user; do
    ssh -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -i "$BOOTSTRAP_KEY" "$user@$ip" "sudo bash -lc '
      set -euo pipefail
      tmp=\"\$(mktemp)\"
      cp /etc/hosts \"\$tmp\"
      sed -i \"/# BEGIN KOVE BM HOSTS/,/# END KOVE BM HOSTS/d\" \"\$tmp\"
      printf \"%s\" \"$HOSTS_BLOCK_B64\" | base64 -d >> \"\$tmp\"
      printf \"\\n\" >> \"\$tmp\"
      cp \"\$tmp\" /etc/hosts
      rm -f \"\$tmp\"
    '" >/dev/null && echo "Updated /etc/hosts on $ip" || echo "WARNING: failed to update /etc/hosts on $ip"
  done < "$HOST_MAP_FILE"
fi

echo "Done. Successfully processed $auth_ok BM node(s)."
if [[ "$auth_ok" -eq 0 ]]; then
  exit 2
fi
