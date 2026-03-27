#!/usr/bin/env bash
set -euo pipefail

# Config-driven helper for head node:
# 1) installs passwordless SSH from head -> BM nodes using a bootstrap key copied from your laptop
# 2) optionally updates /etc/hosts on head + BMs
# 3) optionally installs RDMA auth refresh cron on BMs

CONFIG_FILE="${CONFIG_FILE:-$HOME/kove-bm-bootstrap.conf}"

# Defaults (can be overridden by config file or env vars)
BOOTSTRAP_KEY_PATH="${BOOTSTRAP_KEY_PATH:-$HOME/.ssh/head_login_key}"
BM_IPS="${BM_IPS:-172.16.6.214 172.16.7.211 172.16.5.157 172.16.7.29}"
PRIMARY_USER="${PRIMARY_USER:-cloud-user}"
FALLBACK_USERS="${FALLBACK_USERS:-opc ec2-user}"
HEAD_IDENTITY_KEY="${HEAD_IDENTITY_KEY:-$HOME/.ssh/id_ed25519}"
HEAD_IDENTITY_PUB="${HEAD_IDENTITY_PUB:-$HOME/.ssh/id_ed25519.pub}"
DO_HOSTS_UPDATE="${DO_HOSTS_UPDATE:-true}"
ENABLE_RDMA_CRON="${ENABLE_RDMA_CRON:-true}"
RDMA_INTERFACE="${RDMA_INTERFACE:-eth2}"
RDMA_CRON_SCHEDULE="${RDMA_CRON_SCHEDULE:-*/30 * * * *}"

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

usage() {
  cat <<EOF
Usage:
  ./setup_bm_passwordless_ssh.sh
  CONFIG_FILE=~/kove-bm-bootstrap.conf ./setup_bm_passwordless_ssh.sh

Config file (default: ~/kove-bm-bootstrap.conf) keys:
  BOOTSTRAP_KEY_PATH=~/.ssh/head_login_key
  BM_IPS="172.16.6.214 172.16.7.211 172.16.5.157 172.16.7.29"
  PRIMARY_USER=cloud-user
  FALLBACK_USERS="opc ec2-user"
  HEAD_IDENTITY_KEY=~/.ssh/id_ed25519
  HEAD_IDENTITY_PUB=~/.ssh/id_ed25519.pub
  DO_HOSTS_UPDATE=true
  ENABLE_RDMA_CRON=true
  RDMA_INTERFACE=eth2
  RDMA_CRON_SCHEDULE="*/30 * * * *"
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

expand_path() {
  local p="$1"
  if [[ "$p" == ~* ]]; then
    eval "printf '%s' \"$p\""
  else
    printf '%s' "$p"
  fi
}

BOOTSTRAP_KEY_PATH="$(expand_path "$BOOTSTRAP_KEY_PATH")"
HEAD_IDENTITY_KEY="$(expand_path "$HEAD_IDENTITY_KEY")"
HEAD_IDENTITY_PUB="$(expand_path "$HEAD_IDENTITY_PUB")"

if [[ ! -f "$BOOTSTRAP_KEY_PATH" ]]; then
  echo "ERROR: Bootstrap key not found: $BOOTSTRAP_KEY_PATH"
  echo "Copy your bastion/head login private key to this path first."
  exit 1
fi

# Normalize accidental CRLF in private key and validate.
if grep -q $'\r' "$BOOTSTRAP_KEY_PATH"; then
  sed -i 's/\r$//' "$BOOTSTRAP_KEY_PATH"
fi
chmod 600 "$BOOTSTRAP_KEY_PATH"
if ! ssh-keygen -lf "$BOOTSTRAP_KEY_PATH" >/dev/null 2>&1; then
  echo "ERROR: Invalid private key format at $BOOTSTRAP_KEY_PATH"
  echo "Re-copy key with scp; avoid terminal paste."
  exit 1
fi

if [[ ! -f "$HEAD_IDENTITY_KEY" || ! -f "$HEAD_IDENTITY_PUB" ]]; then
  echo "Head identity key not found, generating $HEAD_IDENTITY_KEY ..."
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  ssh-keygen -t ed25519 -N '' -f "$HEAD_IDENTITY_KEY"
fi

PUB_KEY_CONTENT="$(cat "$HEAD_IDENTITY_PUB")"
if [[ -z "$PUB_KEY_CONTENT" ]]; then
  echo "ERROR: Empty public key at $HEAD_IDENTITY_PUB"
  exit 1
fi
PUB_KEY_B64="$(printf "%s" "$PUB_KEY_CONTENT" | base64 -w0)"

echo "Bootstrap key: $BOOTSTRAP_KEY_PATH"
echo "Head identity key: $HEAD_IDENTITY_KEY"
echo "BM IPs: $BM_IPS"

HOST_MAP_FILE="$(mktemp)"
trap 'rm -f "$HOST_MAP_FILE"' EXIT
ok_count=0

for ip in $BM_IPS; do
  echo "===== $ip ====="
  connected=0
  for u in "$PRIMARY_USER" $FALLBACK_USERS; do
    echo "Trying user: $u"
    if ssh -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -i "$BOOTSTRAP_KEY_PATH" "$u@$ip" "PUB_KEY_B64='$PUB_KEY_B64' bash -s" <<'EOS'
set -euo pipefail
mkdir -p ~/.ssh
chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
KEY="$(printf "%s" "$PUB_KEY_B64" | base64 -d)"
grep -qxF "$KEY" ~/.ssh/authorized_keys || printf "%s\n" "$KEY" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
EOS
    then
      connected=1
      host_short="$(ssh -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -i "$BOOTSTRAP_KEY_PATH" "$u@$ip" 'hostname -s' 2>/dev/null || true)"
      [[ -z "$host_short" ]] && host_short="bm-${ip//./-}"
      echo "$ip $host_short $u" >> "$HOST_MAP_FILE"
      echo "Installed pubkey for $u@$ip (host=$host_short)"

      if ssh -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -i "$HEAD_IDENTITY_KEY" "$u@$ip" 'hostname; whoami' >/dev/null 2>&1; then
        echo "Passwordless SSH verified with $HEAD_IDENTITY_KEY -> $u@$ip"
      else
        echo "WARNING: Passwordless verification failed with $HEAD_IDENTITY_KEY for $u@$ip"
      fi

      if [[ "$ENABLE_RDMA_CRON" == "true" ]]; then
        CRON_LINE="$RDMA_CRON_SCHEDULE root /usr/local/bin/oci-cn-auth-refresh.sh >> /var/log/oci-cn-auth-cron.log 2>&1"
        ssh -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -i "$BOOTSTRAP_KEY_PATH" "$u@$ip" "RDMA_INTERFACE='$RDMA_INTERFACE' CRON_LINE='$CRON_LINE' sudo bash -s" <<'EOS'
set -euo pipefail
cat > /usr/local/bin/oci-cn-auth-refresh.sh <<SCRIPT
#!/bin/bash
set -euo pipefail
DATE=\$(date '+%Y-%m-%d %H:%M:%S')
echo "[\$DATE] Running oci-cn-auth refresh on ${RDMA_INTERFACE}" >> /var/log/oci-cn-auth-cron.log
/usr/bin/oci-cn-auth --interface ${RDMA_INTERFACE} >> /var/log/oci-cn-auth-cron.log 2>&1
SCRIPT
chmod 755 /usr/local/bin/oci-cn-auth-refresh.sh
printf "%s\n" "$CRON_LINE" > /etc/cron.d/oci-cn-auth-refresh
chmod 644 /etc/cron.d/oci-cn-auth-refresh
EOS
        echo "Ensured RDMA auth cron on $ip"
      fi

      ok_count=$((ok_count + 1))
      break
    fi
  done
  if [[ "$connected" -eq 0 ]]; then
    echo "FAILED: Could not access $ip using users: $PRIMARY_USER $FALLBACK_USERS"
  fi
done

if [[ "$DO_HOSTS_UPDATE" == "true" && -s "$HOST_MAP_FILE" ]]; then
  echo "Updating /etc/hosts on head + reachable BMs ..."
  HOSTS_BLOCK_FILE="$(mktemp)"
  {
    echo "# BEGIN KOVE BM HOSTS"
    while read -r ip host _; do
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
  echo "Updated /etc/hosts on head"

  while read -r ip _host user; do
    ssh -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -i "$BOOTSTRAP_KEY_PATH" "$user@$ip" "sudo bash -lc '
      set -euo pipefail
      tmp=\"\$(mktemp)\"
      cp /etc/hosts \"\$tmp\"
      sed -i \"/# BEGIN KOVE BM HOSTS/,/# END KOVE BM HOSTS/d\" \"\$tmp\"
      printf \"%s\" \"$HOSTS_BLOCK_B64\" | base64 -d >> \"\$tmp\"
      printf \"\\n\" >> \"\$tmp\"
      cp \"\$tmp\" /etc/hosts
      rm -f \"\$tmp\"
    '" >/dev/null && echo "Updated /etc/hosts on $ip" || echo "WARNING: Failed /etc/hosts update on $ip"
  done < "$HOST_MAP_FILE"
fi

echo "Done. Successfully processed $ok_count BM node(s)."
if [[ "$ok_count" -eq 0 ]]; then
  exit 2
fi
