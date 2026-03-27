# Kove cluster (head node)

A short copy of this text is written to **`~/README.md`** on the head at first boot (same content as the Terraform `head_home_readme_markdown` local).

**SSH to BMs:** `ssh cloud-user@<BM_private_ip>` (stack Outputs; user may be `opc` on some images).

**Passwordless SSH from this head:** **`docs/HEAD-BM-SSH-README.md`** or **`scripts/setup_bm_passwordless_ssh.sh`** in the repo.

**RDMA on a BM:** `sudo systemctl status oci-cn-auth-refresh.timer`. If missing: `cd /opt/oci-hpc-ansible` then `sudo /usr/local/bin/ansible-playbook -i inventory/hosts configure-rhel-rdma.yml --limit bm`.

**Bootstrap log:** `sudo tail -200 /var/log/oci-hpc-ansible-bootstrap.log`
