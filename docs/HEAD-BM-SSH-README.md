# Head Node BM SSH Bootstrap Guide

This guide fixes BM SSH access from the head node when Ansible cannot log in.

## Why your previous command failed

`Load key ... invalid format` means the private key file on head is malformed (usually copy/paste or CRLF issue).

`Permission denied (publickey)` means the BM rejected the offered key for that user.

## 1) Copy the same local key you use to SSH to head

From your **Windows machine** (PowerShell), copy your private key to head as `~/.ssh/head_login_key`.

Replace `C:\\Users\\ncusato\\.ssh\\id_rsa` with your actual local key path if different.

```powershell
$HEAD_IP = "161.153.91.230"
$LOCAL_KEY = "C:\\Users\\ncusato\\.ssh\\id_rsa"

scp -i "$LOCAL_KEY" "$LOCAL_KEY" "opc@$HEAD_IP:~/.ssh/head_login_key"
```

If your local key is ED25519:

```powershell
$LOCAL_KEY = "C:\\Users\\ncusato\\.ssh\\id_ed25519"
scp -i "$LOCAL_KEY" "$LOCAL_KEY" "opc@$HEAD_IP:~/.ssh/head_login_key"
```

## 2) On head, run one script

```bash
cd ~
chmod 600 ~/.ssh/head_login_key
bash /opt/oci-hpc-ansible/scripts/setup_bm_passwordless_ssh.sh || bash ~/setup_bm_passwordless_ssh.sh
```

If the script is in your repo checkout on head:

```bash
cd ~/kove-oci-build-2
chmod +x scripts/setup_bm_passwordless_ssh.sh
./scripts/setup_bm_passwordless_ssh.sh
```

This script will:
- use `~/.ssh/head_login_key` to reach BM nodes,
- append head's `~/.ssh/id_ed25519.pub` to BM `authorized_keys`,
- verify passwordless SSH with `~/.ssh/id_ed25519`,
- update `/etc/hosts` on head and each reachable BM with a managed `# BEGIN KOVE BM HOSTS` block.

## 3) Test simple SSH to a BM

```bash
ssh -i ~/.ssh/id_ed25519 cloud-user@172.16.6.214
```

## Optional overrides

Different BM list:

```bash
BM_IPS="172.16.6.214 172.16.7.211 172.16.5.157 172.16.7.29" ./scripts/setup_bm_passwordless_ssh.sh
```

Different bootstrap key path:

```bash
BOOTSTRAP_KEY=~/.ssh/my_local_key ./scripts/setup_bm_passwordless_ssh.sh
```

Disable `/etc/hosts` updates:

```bash
DO_HOSTS_UPDATE=false ./scripts/setup_bm_passwordless_ssh.sh
```

## If still failing

Run verbose once:

```bash
ssh -vvv -o IdentitiesOnly=yes -i ~/.ssh/head_login_key cloud-user@172.16.6.214
```

If key is rejected, the BM does not have the matching public key for that user.
