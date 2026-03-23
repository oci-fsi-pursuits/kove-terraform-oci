# OCI HPC BM Cluster Stack

[![Deploy to Oracle Cloud](https://oci-resourcemanager-plugin.plugins.oci.oraclecloud.com/latest/deploy-to-oracle-cloud.svg)](https://cloud.oracle.com/resourcemanager/stacks/create?zipUrl=https://github.com/ncusato/kove-terraform-oci/archive/refs/heads/master.zip)

## What this is

This **OCI Resource Manager** stack builds a small **HPC-style cluster**: a **VCN** (new or existing), a **head VM** (Oracle Linux 8 by default), and a **cluster network** with **4× BM.Optimized3.36** bare metal nodes (RDMA). The bare metal nodes expect a **custom RHEL 8.8** image you import into OCI.

**Time:** Creating the bare metal cluster network often takes **45–90+ minutes**. The head VM is created only after the cluster network is **RUNNING**.

**Full detail** (every Terraform variable, outputs, Ansible troubleshooting, file layout): **[STACK-REFERENCE.md](STACK-REFERENCE.md)**.

---

## Step 1 — RHEL 8.8 image in OCI

Start with Oracle’s overview: **[Bare metal servers on OCI with Red Hat Enterprise Linux](https://blogs.oracle.com/cloud-infrastructure/bare-metal-servers-oci-red-hat-enterprise-linux)**.

You need a **RHEL 8.8** disk image in your compartment (**Compute → Images → Import** from Object Storage). Use a **KVM/qcow2** from [Red Hat downloads](https://access.redhat.com/downloads) or build one with **Image Builder** using the blueprint below.

<details>
<summary><strong>RHEL 8.8 Image Builder blueprint (copy TOML)</strong></summary>

Save as `rhel-8.8-baremetal.toml`. **No SSH keys in the image** — OCI injects `ssh_authorized_keys` at launch. Adjust `distro` / kernel NEVRAs if your Image Builder catalog differs.

```toml
name = "rhel-8.8-baremetal"
description = "RHEL 8.8 baremetal"
version = "1.0.0"
distro = "rhel-8.8"

modules = []
groups = []

[[packages]]
name = "firewalld"
version = "*"

[[packages]]
name = "kernel"
version = "4.18.0-553.el8_10.x86_64"

[[packages]]
name = "kernel-abi-stablelists"
version = "4.18.0-553.el8_10.noarch"

[[packages]]
name = "kernel-core"
version = "4.18.0-553.el8_10.x86_64"

[[packages]]
name = "kernel-headers"
version = "4.18.0-553.el8_10.x86_64"

[[packages]]
name = "kernel-modules"
version = "4.18.0-553.el8_10.x86_64"

[[packages]]
name = "kernel-modules-extra"
version = "4.18.0-553.el8_10.x86_64"

[[packages]]
name = "iscsi-initiator-utils"
version = "*"

[[packages]]
name = "iscsi-initiator-utils-iscsiuio"
version = "*"

[[packages]]
name = "libiscsi"
version = "*"

[[packages]]
name = "udisks2-iscsi"
version = "*"

[customizations.kernel]
append = "rd.iscsi.ibft=1 rd.iscsi.firmware=1 rd.iscsi.param=node.session.timeo.replacement_timeout=6000 network-config=disabled crashkernel=1G-4G:192M,4G-64G:256M,64G-:512M"

[customizations.services]
enabled = ["sshd", "kdump"]

[[customizations.files]]
path = "/etc/sysctl.d/99-sysctl.conf"
mode = "644"
user = "root"
group = "root"
data = "kernel.sysrq = 1\n"

[[customizations.files]]
path = "/etc/dracut.conf"
mode = "644"
user = "root"
group = "root"
data = "add_drivers+=\" be2iscsi bnx2i bnxt_en iscsi_ibft iscsi_tcp mlx5_core pci_hyperv_intf tls \"\nomit_drivers+=\" nvme_fabrics nvme_tcp \"\n"

[[customizations.files]]
path = "/etc/modprobe.d/blacklist.conf"
mode = "644"
user = "root"
group = "root"
data = "blacklist nvme_tcp\nblacklist nvme_fabrics\ninstall nvme_tcp /bin/false\ninstall nvme_fabrics /bin/false\n"
```

**Build (example):** on a subscribed RHEL host — `composer-cli blueprints push rhel-8.8-baremetal.toml` → `composer-cli compose start rhel-8.8-baremetal qcow2` → download when **FINISHED**, then import: [Importing a custom image](https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/importingcustomimage.htm).

Use the image **OCID** in **Step 3**.

</details>

---

## Step 2 — Create the stack in Resource Manager

1. Click **Deploy to Oracle Cloud** at the top of this page (OCI downloads the GitHub zip and opens **Create stack**), **or**
2. Zip the repo files and choose **Upload my Terraform configuration**.

Include at least: `main.tf`, `variables.tf`, `outputs.tf`, `schema.yaml`, `scripts/`, `playbooks/`, and `inventory.tpl` if present. Exact zip commands and checklist → **[STACK-REFERENCE.md](STACK-REFERENCE.md#deployment-steps)**.

Console path: **Resource Manager → Stacks → Create stack**.

---

## Step 3 — Configure variables (wizard)

| Console / purpose | What to enter |
|-------------------|----------------|
| **Compartment** | Where resources are created |
| **SSH public key** | The key you use to SSH to instances |
| **BM / RHEL image** | OCID of your **RHEL 8.8** image (Step 1) |
| **Head image** | Leave **empty** for latest **Oracle Linux 8** (recommended) |

**Optional**

- **Use existing VCN** — set the option and paste **VCN**, **public subnet**, and **private subnet** OCIDs. Optional **cluster network availability domain** (e.g. `Uocm:PHX-AD-1`) if the cluster network goes **TERMINATED** immediately — see [STACK-REFERENCE.md — Troubleshooting](STACK-REFERENCE.md#terraform-errors).
- **Run Ansible from head at first boot** = **true** — set **RHSM username/password** for the BMs and paste the **SSH private key** that matches your public key (so the head can SSH to the BMs). Add the head to a **dynamic group** and grant **instance principal** policies; full steps → **[STACK-REFERENCE.md — Run Ansible from head](STACK-REFERENCE.md#run-ansible-from-head-node-resource-manager)**.

**If something fails:** cluster network apply timeout → increase **Cluster network create timeout** (e.g. `2h`). Empty Ansible BM inventory or BM data source errors → try **BM pool ready wait** (e.g. `15m`).

**All variable names, types, and defaults** → **[STACK-REFERENCE.md](STACK-REFERENCE.md#terraform-variables)**.

---

## Step 4 — Plan and apply

1. **Plan** — review the plan.  
2. **Apply** — deploy.  
3. Wait for the job; bare metal provisioning is often **45–90+ minutes**.

---

## Step 5 — Log in

- Open the job **Outputs** for **head public IP** and **BM private IPs** (see [outputs](STACK-REFERENCE.md#terraform-outputs) in the reference).
- **Head (Oracle Linux):** `ssh opc@<head_public_ip>`
- **BM nodes (RHEL), from the head:** `ssh cloud-user@<bm_private_ip>`

If you enabled Ansible from the head, check on the head: **`/var/log/oci-hpc-ansible-bootstrap.log`**.

**Troubleshooting** (SSH, timeouts, Ansible, `/etc/hosts`) → **[STACK-REFERENCE.md](STACK-REFERENCE.md#troubleshooting)**.

---

## More documentation

| Document | Contents |
|----------|----------|
| **[STACK-REFERENCE.md](STACK-REFERENCE.md)** | Terraform variables, deployment zip, outputs, Ansible-from-head, playbook notes, file tree, customization |
| **[OCI-RESOURCE-MANAGER-GUIDE.md](OCI-RESOURCE-MANAGER-GUIDE.md)** | Deploy button, `schema.yaml`, Resource Manager behavior |

---

## References

- [OCI HPC cluster network](https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/hpc-cluster-network.htm)
- [OCI Resource Manager](https://docs.oracle.com/en-us/iaas/Content/ResourceManager/Concepts/resourcemanager.htm)
- [RDMA on OCI](https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/hpc-rdma.htm)
- [Import custom image](https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/importingcustomimage.htm)
- [RHEL on OCI bare metal (Oracle blog)](https://blogs.oracle.com/cloud-infrastructure/bare-metal-servers-oci-red-hat-enterprise-linux)

## License

This stack is based on the Oracle Quickstart OCI HPC Stack and follows similar licensing terms.
