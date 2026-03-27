#!/bin/bash
set -e
LOG=/var/log/oci-hpc-ansible-bootstrap.log
mkdir -p /var/log
echo "$(date) B: start 90s" | tee -a "$LOG"

do_bootstrap() {
  exec >> "$LOG" 2>&1
  echo "$(date) B: go"

  COMPARTMENT_ID="${compartment_id}"
  SSH_USER="${instance_ssh_user}"
  HEAD_SSH_USER="${head_node_ssh_user}"
  ANSIBLE_DIR="/opt/oci-hpc-ansible"
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
      ssh-keygen -y -f "$_sshdir/id_ed25519" > "$_sshdir/id_ed25519.pub" 2>/dev/null || true
      chmod 644 "$_sshdir/id_ed25519.pub" 2>/dev/null || true
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
  if [ ! -f /opt/oci-hpc-playbooks.zip ]; then
    echo "$(date) B: ERROR missing /opt/oci-hpc-playbooks.zip" >&2
    exit 1
  fi
  if command -v unzip >/dev/null 2>&1; then
    unzip -o -q /opt/oci-hpc-playbooks.zip -d "$ANSIBLE_DIR"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c "import zipfile; zipfile.ZipFile('/opt/oci-hpc-playbooks.zip','r').extractall('$ANSIBLE_DIR')"
  else
    echo "$(date) B: need unzip" >&2
    exit 1
  fi
  echo "$EXTRA_VARS_B64" | base64 -d > "$ANSIBLE_DIR/extra_vars.yml"

  if [ -z "$BM_PRIVATE_IPS_CSV" ]; then
    echo "$(date) B: ERROR empty BM_PRIVATE_IPS_CSV" >&2
    exit 1
  fi
  echo "$(date) B: inv..."
  mkdir -p "$ANSIBLE_DIR/inventory"
  HEAD_IP=$(hostname -I | awk '{print $1}')
  echo "[head]
head-node ansible_host=$HEAD_IP ansible_user=$HEAD_SSH_USER ansible_connection=local

[bm]" > "$ANSIBLE_DIR/inventory/hosts"
  i=1
  for _ip in $(echo "$BM_PRIVATE_IPS_CSV" | tr ',' ' '); do
    _ip=$(echo "$_ip" | tr -d ' ')
    [ -z "$_ip" ] && continue
    _bu="$SSH_USER"
    for _try in "$SSH_USER" opc cloud-user ec2-user; do
      [ -z "$_try" ] && continue
      ssh -i /root/.ssh/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes "$${_try}@$${_ip}" true 2>/dev/null && {
        _bu="$_try"
        break
      }
    done
    echo "$(date) B: bm-node-$i $_ip ansible_user=$_bu"
    echo "bm-node-$i ansible_host=$_ip ansible_user=$_bu" >> "$ANSIBLE_DIR/inventory/hosts"
    i=$((i+1))
  done
  BM_ADDED=$((i-1))
  echo "$(date) B: +$BM_ADDED BM" >> "$LOG"
  if [ "$BM_ADDED" -eq 0 ]; then
    echo "$(date) B: [bm] empty" >> "$LOG"
  fi
  echo "" >> "$ANSIBLE_DIR/inventory/hosts"
  echo "[bm:vars]" >> "$ANSIBLE_DIR/inventory/hosts"
  echo "ansible_ssh_private_key_file=/root/.ssh/id_ed25519" >> "$ANSIBLE_DIR/inventory/hosts"

  echo "[all:children]
head
bm" >> "$ANSIBLE_DIR/inventory/hosts"

  echo "$(date) B: Ansible..."
  cd "$ANSIBLE_DIR"
  export ANSIBLE_HOST_KEY_CHECKING=False
  # pip installs here; sudo's secure_path often omits /usr/local/bin — always prefer absolute path.
  if [ -x /usr/local/bin/ansible-playbook ]; then
    ANSIBLE_PLAYBOOK=/usr/local/bin/ansible-playbook
  else
    ANSIBLE_PLAYBOOK=$(command -v ansible-playbook 2>/dev/null || true)
  fi
  if [ -z "$ANSIBLE_PLAYBOOK" ] || [ ! -x "$ANSIBLE_PLAYBOOK" ]; then
    echo "$(date) B: ERROR ansible-playbook not found (install pip ansible or use /usr/local/bin)" >&2
    exit 1
  fi
  set +e
  "$ANSIBLE_PLAYBOOK" -i inventory/hosts configure-rhel-rdma.yml -e @extra_vars.yml
  _apb=$?
  set -e
  echo "$(date) B: ansible-playbook exit code: $_apb (0=ok)"
  if [ "$_apb" -ne 0 ]; then
    echo "$(date) B: WARNING re-run (sudo hides /usr/local/bin; use full path): cd $ANSIBLE_DIR && sudo $ANSIBLE_PLAYBOOK -i inventory/hosts configure-rhel-rdma.yml -e @extra_vars.yml"
  fi

  echo "$(date) B: done"
}

# Background subshell: avoid bash -c "$(declare -f do_bootstrap)" (breaks on " in function body).
(
  sleep 90
  do_bootstrap
) >> "$LOG" 2>&1 &
echo "$(date) B: bg sleep90 -> $LOG"
