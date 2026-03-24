# Kove Infra Build on OCI

[![Deploy to Oracle Cloud](https://oci-resourcemanager-plugin.plugins.oci.oraclecloud.com/latest/deploy-to-oracle-cloud.svg)](https://cloud.oracle.com/resourcemanager/stacks/create?zipUrl=https://github.com/ncusato/kove-terraform-oci/archive/refs/tags/Kove-RHEL88-OCI.zip)

*Deploy uses Git tag **`Kove-RHEL88-OCI`** (not `master`). GitHub’s download is usually named `kove-terraform-oci-Kove-RHEL88-OCI.zip`; you can rename it to **`Kove-RHEL88-OCI.zip`** before upload if you want that exact filename. To refresh the zip after changes, move the tag to the latest commit and push the tag again.*

## Background: Kove and why this stack targets OCI

**[Kove](https://kove.com/)** builds **Kove:SDM™** (*software-defined memory*)—technology that lets many servers share and grow effective memory capacity from a common pool so large, memory-heavy jobs (HPC, AI, analytics, and similar) are less constrained by a single machine’s RAM. Learn more on **[kove.com](https://kove.com/)**.

This repository is **infrastructure-as-code** for a **bare-metal cluster footprint on Oracle Cloud Infrastructure (OCI)** used in that kind of environment. It is not a substitute for Kove product documentation; it provisions network, head + worker nodes, and optional automation so you can run **RHEL on OCI bare metal** with **RDMA-oriented** setup.

**Why OCI (and how it differs from typical generic cloud VMs)**

Other hyperscalers offer VMs, some offer bare metal or isolated RDMA SKUs, but the **combination** this stack assumes is what draws this workload to **OCI** in practice:

| Theme | Why it matters here |
|--------|---------------------|
| **Bare metal shapes** | Workloads that care about memory virtualization and **latency** often need **dedicated hosts** (e.g. **BM.Optimized3**), not a shared hypervisor slice, so behavior matches physical servers more closely. |
| **RDMA** | **Remote direct memory access** matters for **low CPU overhead** and **low latency** between nodes. OCI documents **HPC / RDMA**-style networking for suitable shapes; this stack’s Ansible path configures **RHEL** side **RDMA auth** on the BMs. Many default “VPC only” footprints elsewhere **do not** expose the same **RDMA-on-bare-metal** story without different SKUs or constraints. |
| **Non-blocking / HPC-style networking** | **HPC cluster** networking aims at **predictable, low-contention** bandwidth between nodes. Generic cloud **oversubscribed** virtual networks are often a poor match for **tightly coupled** memory and I/O patterns; OCI’s **HPC-oriented** networking model is aligned with that requirement. |
| **Off-box / pooled memory** | **Software-defined memory** implies a lot of **fast host-to-host** traffic. That fits best with **stable physical placement**, **RDMA where available**, and **minimal in-path virtualization**—the pattern this Terraform stack is built around on **OCI**. |

So: the stack is **OCI-specific** because it relies on **OCI bare metal**, **documented RDMA / HPC networking patterns**, and **compute-cluster style placement**—not because application code cannot run elsewhere, but because **those ingredients together** are the usual prerequisite for this class of deployment.

---

## What this is

This **OCI Resource Manager** / Terraform stack builds a small **HPC-style cluster**:

- A **VCN** (create new or use existing subnets).
- A **head VM** (Oracle Linux 8 by default) for operations and optional Ansible.
- A **compute cluster** with **bare metal** nodes (**BM.Optimized3.36** by default, count configurable). Nodes use a **custom RHEL** image you import into OCI.

Bare metal provisioning is **slow** compared to VMs (often **tens of minutes per node**; allow **up to ~2 hours** in a busy region). The head VM is created **after** the bare metal instances exist when **Run Ansible from head** is enabled (Terraform waits so `user_data` can include BM private IPs).

**Full detail** (variables, outputs, troubleshooting, file layout): **[STACK-REFERENCE.md](STACK-REFERENCE.md)**.

---

## Prerequisites

Read this once before you deploy. Nothing here belongs in Git—use placeholders in docs and keep secrets in local files only (see **Secrets** below).

### What you need in OCI

| Item | Why |
|------|-----|
| **Tenancy + compartment** | All resources are created in a compartment you choose. |
| **Networking** | Either let the stack create a VCN and subnets, or supply OCIDs for an **existing VCN**, **public subnet** (head), and **private subnet** (bare metal). |
| **Custom RHEL image** | Bare metal nodes boot from a **RHEL** image you **import** (see Step 1). Match the stack variable for **BM image OCID**. |
| **SSH public key** | OCI injects this at launch. You only ever need the **public** key in Terraform / the stack wizard—**never** commit private keys. |
| **Bare metal capacity** | **BM.Optimized3.36** (or your chosen shape) must be available in the **availability domain** you use. If launches fail with **out of host capacity**, try another AD, a **capacity reservation**, fewer nodes, or retry later. |

### IAM for the person running Terraform (API user or group)

Whoever runs **Plan/Apply** (Resource Manager job owner, or `terraform` on a laptop) needs permission to manage the resources this stack creates—for example:

- **Compute:** instances, images (read), optional compute cluster
- **Networking:** VCN, subnets, gateways, route tables, security lists (if creating VCN)
- **Identity (read):** availability domains

Exact statements depend on your tenancy. A **starting point** (replace names in angle brackets) is:

```text
Allow group <your-terraform-admins> to manage instance-family in compartment <compartment_name>
Allow group <your-terraform-admins> to use virtual-network-family in compartment <compartment_name>
Allow group <your-terraform-admins> to manage compute-management-family in compartment <compartment_name>
```

Tighten or broaden to match your security standards. Resource Manager execution may use a **different** principal—grant the same ideas to the RM-managed **resource** principal or service if your org requires it.

### Optional: “Run Ansible from head at first boot”

If you set **`run_ansible_from_head = true`**, the head node’s **cloud-init** unpacks the **`playbooks/`** tree to **`/opt/oci-hpc-ansible`** and runs **`configure-rhel-rdma.yml`**. That path uses the **OCI CLI** with **instance principal** (no API key on disk).

**You must configure this in IAM before relying on it:**

1. **Dynamic group** — Identity → Domains → Dynamic groups → **Create**. Matching rule (use your **compartment OCID**):

   ```text
   ALL { instance.compartment.id = '<your_compartment_ocid>' }
   ```

   Narrow the rule (tags, name patterns) if policy allows.

2. **Policies** for that dynamic group — attach in the compartment or tenancy (replace `<dynamic_group_name>` and `<compartment_name>`):

   ```text
   Allow dynamic-group <dynamic_group_name> to read instance-family in compartment <compartment_name>
   Allow dynamic-group <dynamic_group_name> to use virtual-network-family in compartment <compartment_name>
   ```

   If `list-vnics` / inventory discovery still fails, add the broader pattern used in [oracle-quickstart/oci-hpc](https://github.com/oracle-quickstart/oci-hpc) (e.g. **manage compute-management-family** in that compartment) or, only for labs, a scoped **manage all-resources** in that compartment.

3. **Red Hat subscriptions** — For RHEL on the bare metal nodes, provide **RHSM** credentials (stack variables or a local `secrets.auto.tfvars` file). The head can stay on **Oracle Linux** and does not need RHSM for itself.

4. **First boot only** — OCI **`user_data`** runs on the instance’s **first boot**. If you change **`run_ansible_from_head`** or the embedded playbooks, **replace the head instance** (e.g. `terraform apply -replace=oci_core_instance.head_node`) so cloud-init runs again.

5. **Metadata size limit** — Instance metadata is capped at **32 KB**. This stack **does not** ship the large legacy **`site.yml`** in the embedded zip so the bundle stays under the limit. The playbook you run is **`configure-rhel-rdma.yml`**.

**Logs on the head:** `/var/log/oci-hpc-ansible-bootstrap.log`

### Secrets (do not push to GitHub)

These file names are in **`.gitignore`**—keep them local:

| File | Purpose |
|------|---------|
| **`terraform.tfvars`** | Your OCIDs, region, flags—copy from **`terraform.tfvars.example`**. |
| **`secrets.auto.tfvars`** | RHSM password and other secrets (Terraform loads `*.auto.tfvars` automatically). |

Commit **only** `terraform.tfvars.example` (placeholders). Rotate any credential that was ever pasted into a tracked file by mistake.

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

A matching Image Builder blueprint is also in the repo as **`oci_8.8_baremetal.toml`** (same content as the collapsible example above).

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

- **Use existing VCN** — set the option and paste **VCN**, **public subnet**, and **private subnet** OCIDs. Optional **BM / compute cluster availability domain** (e.g. `pILZ:PHX-AD-2`) if bare metal hits **capacity** errors in the default AD — see [STACK-REFERENCE.md — Troubleshooting](STACK-REFERENCE.md#terraform-errors).
- **Run Ansible from head at first boot** = **true** — set **RHSM username/password** for the BMs (or use **`secrets.auto.tfvars`**). The head uses a **Terraform-generated SSH key** (already on the BMs) to run Ansible—no separate private-key variable. You still need the **dynamic group** and **instance principal** policies described under **Prerequisites** above; more detail → **[STACK-REFERENCE.md — Run Ansible from head](STACK-REFERENCE.md#run-ansible-from-head-node-resource-manager)**.

**If something fails:** bare metal **create timeout** → increase **BM instance create timeout** (variable label may still say “cluster network”; e.g. `2h`). Empty Ansible **`[bm]`** inventory → increase **BM pool ready wait** (e.g. `15m`) or confirm **`user_data`** was applied (replace head after enabling Ansible).

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
| **This README** | Overview, **prerequisites** (IAM, capacity, secrets), high-level steps |
| **[STACK-REFERENCE.md](STACK-REFERENCE.md)** | Terraform variables, deployment zip, outputs, Ansible-from-head, playbook notes, file tree, customization |
| **[OCI-RESOURCE-MANAGER-GUIDE.md](OCI-RESOURCE-MANAGER-GUIDE.md)** | Deploy button, `schema.yaml`, Resource Manager behavior, **desktop Terraform (Windows)** |

---

## References

- [OCI compute clusters](https://docs.oracle.com/en-us/iaas/Content/Compute/References/computeclusters.htm)
- [OCI HPC cluster network](https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/hpc-cluster-network.htm) (related; this stack uses **compute cluster + instances** by default)
- [OCI Resource Manager](https://docs.oracle.com/en-us/iaas/Content/ResourceManager/Concepts/resourcemanager.htm)
- [RDMA on OCI](https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/hpc-rdma.htm)
- [Import custom image](https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/importingcustomimage.htm)
- [RHEL on OCI bare metal (Oracle blog)](https://blogs.oracle.com/cloud-infrastructure/bare-metal-servers-oci-red-hat-enterprise-linux)

## License

This stack is based on the Oracle Quickstart OCI HPC Stack and follows similar licensing terms.
