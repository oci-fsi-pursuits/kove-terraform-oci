#!/bin/bash
set -e
LOG=/var/log/oci-hpc-ansible-bootstrap.log
mkdir -p /var/log
echo "$(date) B: start 90s" | tee -a "$LOG"

do_bootstrap() {
  exec >> "$LOG" 2>&1
  echo "$(date) B: go"

  INSTANCE_POOL_ID="${instance_pool_id}"
  COMPARTMENT_ID="${compartment_id}"
  BM_COUNT=${bm_count}
  SSH_USER="${instance_ssh_user}"
  HEAD_SSH_USER="${head_node_ssh_user}"
  ANSIBLE_DIR="/opt/oci-hpc-ansible"
  PAYLOAD_B64="${payload_b64}"
  EXTRA_VARS_B64="${extra_vars_b64}"
  RHSM_USER_B64="${rhsm_username_b64}"
  RHSM_PASS_B64="${rhsm_password_b64}"
  BM_PRIVATE_IPS_CSV="${bm_private_ips_csv}"
  SSH_PRIVATE_KEY_B64="${ssh_private_key_b64}"

  export PATH="/usr/local/bin:/usr/bin:$PATH"
  export OCI_CLI_AUTH=instance_principal
  export OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING=True
  REGION="${region}"
  TENANCY="${tenancy_ocid}"
  for _u in root "$HEAD_SSH_USER"; do
    [ -z "$_u" ] && continue
    _d="/home/$_u/.oci"
    [ "$_u" = "root" ] && _d="/root/.oci"
    mkdir -p "$_d"
    printf '[DEFAULT]\nauth=instance_principal\nregion=%s\ntenancy=%s\n' "$REGION" "$TENANCY" > "$_d/config"
    chmod 600 "$_d/config" 2>/dev/null || true
    chown -R "$_u:$_u" "$_d" 2>/dev/null || true
  done

  if [ -n "$SSH_PRIVATE_KEY_B64" ]; then
    for _u in root "$HEAD_SSH_USER"; do
      [ -z "$_u" ] && continue
      _sshdir="/home/$_u/.ssh"
      [ "$_u" = "root" ] && _sshdir="/root/.ssh"
      mkdir -p "$_sshdir"
      echo "$SSH_PRIVATE_KEY_B64" | base64 -d > "$_sshdir/id_ed25519"
      chmod 600 "$_sshdir/id_ed25519"
      chown -R "$_u:$_u" "$_sshdir" 2>/dev/null || true
    done
  fi

  if grep -q "Red Hat" /etc/redhat-release 2>/dev/null && ! grep -qi "Oracle" /etc/redhat-release 2>/dev/null && [ -n "$RHSM_USER_B64" ] && [ -n "$RHSM_PASS_B64" ]; then
    RHSM_USER=$(echo "$RHSM_USER_B64" | base64 -d 2>/dev/null)
    RHSM_PASS=$(echo "$RHSM_PASS_B64" | base64 -d 2>/dev/null)
    if [ -n "$RHSM_USER" ] && [ -n "$RHSM_PASS" ]; then
      echo "$(date) B: RHSM..."
      subscription-manager register --username "$RHSM_USER" --password "$RHSM_PASS" --auto-attach --force 2>/dev/null || true
      subscription-manager release --set=8.8 2>/dev/null || true
      subscription-manager repos --enable=rhel-8-for-x86_64-baseos-rpms --enable=rhel-8-for-x86_64-appstream-rpms 2>/dev/null || true
    fi
  else
    echo "$(date) B: skip RHSM"
  fi

  echo "$(date) B: pkg..."
  dnf install -y python3 python3-pip jq unzip || yum install -y python3 python3-pip jq unzip || true
  echo "$(date) B: pip..."
  pip3 install --break-system-packages ansible oci-cli 2>/dev/null || pip3 install ansible oci-cli 2>/dev/null || true

  echo "$(date) B: zip..."
  mkdir -p "$ANSIBLE_DIR"
  echo "$PAYLOAD_B64" | base64 -d > /tmp/playbooks.zip
  if command -v unzip >/dev/null 2>&1; then
    unzip -o -q /tmp/playbooks.zip -d "$ANSIBLE_DIR"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c "import zipfile; zipfile.ZipFile('/tmp/playbooks.zip','r').extractall('$ANSIBLE_DIR')"
  else
    echo "$(date) B: need unzip" >&2
    exit 1
  fi
  rm -f /tmp/playbooks.zip
  echo "$EXTRA_VARS_B64" | base64 -d > "$ANSIBLE_DIR/extra_vars.yml"

  if [ -z "$BM_PRIVATE_IPS_CSV" ]; then
    echo "$(date) B: wait pool $BM_COUNT..."
    for i in $(seq 1 90); do
      N=$(oci compute-management instance-pool list-instances --instance-pool-id "$INSTANCE_POOL_ID" --compartment-id "$COMPARTMENT_ID" --all 2>/dev/null | jq -r '.data | length' 2>/dev/null || echo "0")
      N=$${N:-0}
      if [ "$${N}" -eq "$BM_COUNT" ] 2>/dev/null; then
        echo "$(date) B: found $BM_COUNT"
        break
      fi
      echo "$(date) B: $${N}/$BM_COUNT..."
      sleep 30
    done
  else
    echo "$(date) B: TF IPs"
  fi

  echo "$(date) B: inv..."
  mkdir -p "$ANSIBLE_DIR/inventory"
  HEAD_IP=$(hostname -I | awk '{print $1}')
  echo "[head]
head-node ansible_host=$HEAD_IP ansible_user=$HEAD_SSH_USER ansible_connection=local

[bm]" > "$ANSIBLE_DIR/inventory/hosts"

  if [ -n "$BM_PRIVATE_IPS_CSV" ]; then
    i=1
    for _ip in $(echo "$BM_PRIVATE_IPS_CSV" | tr ',' ' '); do
      _ip=$(echo "$_ip" | tr -d ' ')
      [ -z "$_ip" ] && continue
      echo "bm-node-$i ansible_host=$_ip ansible_user=$SSH_USER" >> "$ANSIBLE_DIR/inventory/hosts"
      i=$((i+1))
    done
    BM_ADDED=$((i-1))
    echo "$(date) B: +$BM_ADDED BM" >> "$LOG"
  else
    i=1
    for inst_id in $(oci compute-management instance-pool list-instances --instance-pool-id "$INSTANCE_POOL_ID" --compartment-id "$COMPARTMENT_ID" --all --query 'data[*].instanceId' --raw-output 2>/dev/null); do
      PRIV_IP=""
      for _try in 1 2; do
        RAW=$(oci compute instance list-vnics --instance-id "$inst_id" --compartment-id "$COMPARTMENT_ID" --all 2>/dev/null) || true
        PRIV_IP=$(echo "$RAW" | jq -r '.data[]? | select(."is-primary" == true or .isPrimary == true) | .privateIp // ."private-ip" // empty' 2>/dev/null | head -1)
        if [ -z "$PRIV_IP" ] || [ "$PRIV_IP" = "null" ]; then
          PRIV_IP=$(echo "$RAW" | jq -r '.data[0]? | .privateIp // ."private-ip" // .vnic.privateIp // .vnic."private-ip" // empty' 2>/dev/null)
        fi
        if [ -z "$PRIV_IP" ] || [ "$PRIV_IP" = "null" ]; then
          PRIV_IP=$(echo "$RAW" | jq -r '.data[]? | .privateIp // ."private-ip" // .vnic.privateIp // .vnic."private-ip" // empty | select(. != null and . != "")' 2>/dev/null | head -1)
        fi
        if [ -z "$PRIV_IP" ] || [ "$PRIV_IP" = "null" ]; then
          PRIV_IP=$(echo "$RAW" | jq -r '[.. | strings | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$"))] | first // empty' 2>/dev/null)
        fi
        if [ -n "$PRIV_IP" ] && [ "$PRIV_IP" != "null" ]; then
          break
        fi
        [ "$_try" -eq 1 ] && sleep 15
      done
      if [ -n "$PRIV_IP" ] && [ "$PRIV_IP" != "null" ]; then
        echo "bm-node-$i ansible_host=$PRIV_IP ansible_user=$SSH_USER" >> "$ANSIBLE_DIR/inventory/hosts"
        i=$((i+1))
      else
        echo "$(date) B: no IP $inst_id" >> "$LOG"
      fi
    done
    BM_ADDED=$((i-1))
    echo "$(date) B: +$BM_ADDED BM" >> "$LOG"
    if [ "$BM_ADDED" -eq 0 ]; then
      echo "$(date) B: [bm] empty" >> "$LOG"
    fi
  fi

  echo "[all:children]
head
bm" >> "$ANSIBLE_DIR/inventory/hosts"

  echo "$(date) B: Ansible..."
  cd "$ANSIBLE_DIR"
  export ANSIBLE_HOST_KEY_CHECKING=False
  ANSIBLE_PLAYBOOK=$(command -v ansible-playbook 2>/dev/null || echo "/usr/local/bin/ansible-playbook")
  $ANSIBLE_PLAYBOOK -i inventory/hosts configure-rhel-rdma.yml -e @extra_vars.yml || true

  echo "$(date) B: done"
}

( nohup bash -c "$(declare -f do_bootstrap); sleep 90; do_bootstrap" >> "$LOG" 2>&1 & )
echo "$(date) B: 90s $LOG"
