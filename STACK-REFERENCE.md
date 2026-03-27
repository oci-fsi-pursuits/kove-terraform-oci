# Stack reference: Terraform, variables, Ansible, troubleshooting

This document supplements the **[README](README.md)** with Terraform **variable** definitions, detailed **deployment** steps, **Ansible from head** setup, **troubleshooting**, file layout, and customization.

---

## Terraform / Ansible

| What | Notes |
|------|--------|
| **Deploy** | Use the **Deploy to Oracle Cloud** button in the [README](README.md) or zip `main.tf`, `variables.tf`, `outputs.tf`, `schema.yaml`, `scripts/`, `playbooks/` (+ `inventory.tpl` if used) and create a stack in **Resource Manager**. |
| **Image** | Set **`bm_node_image_ocid`** to your RHEL 8.8 custom image. Leave **`head_node_image_ocid`** empty to use latest **Oracle Linux 8** on the head. |
| **SSH** | **`ssh_public_key`** is your login key. When **Run Ansible from head** is **true**, the head uses the **Terraform-generated ED25519** private key (embedded in bootstrap) to SSH to BMs; that key's public half is already on all nodes. |
| **Ansible from head** | Set **`run_ansible_from_head`** = true, **`rhsm_username`** / **`rhsm_password`** for BMs, dynamic group + policy for **instance principal** (see [Run Ansible from head node](#run-ansible-from-head-node-resource-manager)). Bootstrap log: **`/var/log/oci-hpc-ansible-bootstrap.log`**. |
| **Timeouts** | Empty **`cluster_network_create_timeout`** uses **`max(oci-hpc formula, 120m)`** (BM fabric often needs &gt;30m). Override with e.g. `180m` if Console still shows PROVISIONING. **`bm_pool_ready_wait`** default **10m** after RUNNING. |

### Compared to [aeron-terraform-oci](https://github.com/ncusato/aeron-terraform-oci)

That stack deploys **regular flex VMs** via **`oci_core_instance`** with explicit **`controller_ad`** / **`benchmark_ad`** ? no **`oci_core_cluster_network`**, no **BM.Optimized3.36**, no RDMA island. VM instances usually reach **RUNNING** in minutes, so Terraform rarely times out. **This stack** provisions an **HPC bare metal cluster network** (different Compute API); **PROVISIONING** for 30?120+ minutes is normal OCI behavior, not something you fix by copying Aeron?s `compute.tf`. Use a long enough **`cluster_network_create_timeout`** and confirm **`cluster_network_availability_domain`** (same idea as Aeron?s required AD vars) matches where your private subnet and shape are supported.

---

## Prerequisites

1. **OCI Account** with appropriate permissions:
   - Ability to create compute instances
   - Ability to create VCNs and subnets (if creating new VCN)
   - Access to BM.Optimized3.36 shape (may require service limits increase)

2. **Authentication:** This stack is for OCI Resource Manager only. It uses the **resource principal** (no API keys). The user running the stack must have permission to create the resources in the chosen compartment.

3. **Custom Image**: RHEL **8.8** image OCID in the target compartment (build/import steps are in the [README](README.md) ? *Image build*).

4. **SSH Key Pair**:
   - Public key for instance access

## Terraform Variables

### Required Variables

| Variable | Type | Description |
|----------|------|-------------|
| `tenancy_ocid` | String | Tenancy OCID (pre-filled from your session in the Console) |
| `region` | String | Region (pre-filled from your session in the Console) |
| `compartment_ocid` | String | Compartment where resources will be created |
| `ssh_public_key` | String | SSH public key to inject into instances |
| `bm_node_image_ocid` | String | RHEL 8.8 image OCID for BM cluster network nodes |
| `head_node_image_ocid` | String | *(Optional)* Image for the head node. **If empty, latest Oracle Linux 8 is used** (recommended; no RHSM on head). Ansible registers RHEL only on BM nodes. Set to override (e.g. a specific OL image). |

### Network Configuration

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `use_existing_vcn` | Boolean | false | Use existing VCN (true) or create new (false) |
| `existing_vcn_id` | String | "" | Existing VCN OCID (required if `use_existing_vcn = true`) |
| `existing_public_subnet_id` | String | "" | Existing public subnet OCID for head node |
| `existing_private_subnet_id` | String | "" | Existing private subnet OCID for BM nodes |
| `cluster_network_availability_domain` | String | "" | Same role as oci-hpc **`ad`**; empty = first tenancy AD |
| `bm_boot_volume_size_gbs` | Number | 120 | BM boot volume size in GB |
| `cluster_network_create_timeout` | String | "" | Empty = **max(oci-hpc formula, 120m)**. Set e.g. `180m` if still timing out. |

**Note**: When `use_existing_vcn = true`, you must provide all three existing resource IDs. When `use_existing_vcn = false`, a new VCN will be created with:
- VCN CIDR: 10.0.0.0/16
- Public subnet CIDR: 10.0.1.0/24
- Private subnet CIDR: 10.0.2.0/24

**Cluster network placement** uses **`primary_vnic_subnets` only** (private subnet). OCI **CreateClusterNetwork** for **BM.Optimized3.36** rejects any **`secondary_vnic_subnets`** (`400-InvalidParameter`: *0 secondaryVnicsSubnets* required) ? same idea as [oci-hpc](https://github.com/oracle-quickstart/oci-hpc) `primary_subnet_id`?only placement.

### Ansible from head (Resource Manager)

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `run_ansible_from_head` | Boolean | true | If true, head node runs the RHEL + RDMA Ansible playbook at first boot via cloud-init (`/opt/oci-hpc-ansible`). Set false only to skip `user_data`. |
| `instance_ssh_user` | String | `opc` | Ansible SSH user on BM nodes (OCI default is usually `opc`; use `cloud-user` only if your image provisions it) |
| `head_node_ssh_user` | String | `opc` | SSH user on head node (`opc` for Oracle Linux head image). |
| `rhsm_username` | String | "" | RHSM username (required when `run_ansible_from_head = true`) |
| `rhsm_password` | String | "" | RHSM password (required when `run_ansible_from_head = true`) |
| `rdma_ping_target` | String | "" | Optional IP for RDMA ping check (e.g. another BM node's RDMA interface) |
| `bm_pool_ready_wait` | String | "10m" | Wait after RUNNING before **`oci_core_cluster_network_instances`** + **`oci_core_instance`** (oci-hpc **data.tf** pattern). |

**Recommended:** Set **Head node image** to an **Oracle Linux** image. The head then uses free OL repos (no RHSM), installs Ansible and OCI CLI, and runs the playbook; Ansible registers **RHEL only on the BM nodes** and does all installs there.

When `run_ansible_from_head = true`, the head node must be in an OCI **dynamic group** with a policy that allows **instance principal** to read instances and VNICs in the compartment (Terraform usually embeds BM private IPs; OCI CLI may still list VNICs). See [Run Ansible from head node](#run-ansible-from-head-node-resource-manager) for setup.

## Deployment Steps

### Option 1: Deploy via OCI Resource Manager (Recommended)

**One-click deploy:** Use the [Deploy to Oracle Cloud](https://cloud.oracle.com/resourcemanager/stacks/create?zipUrl=https://github.com/ncusato/kove-terraform-oci/archive/refs/heads/master.zip) button in the [README](README.md). The zip is built from the **`master`** branch (latest commit on push).

**To get automatic cluster setup (Ansible at first boot):** The stack wizard defaults **"Run Ansible from head at first boot"** to **Yes**; set RHSM username/password for RHEL BMs. **SSH login:** Your **SSH public key** is on the head and BMs; a **Terraform-generated ED25519** key pair is also on all nodes. The bootstrap embeds the **generated private key** (small) on the head so Ansible can SSH to BMs ? **you do not pass a separate SSH private key variable.** If **Run Ansible from head** is **No** / false, the head has **no** `user_data`: **`/opt/oci-hpc-ansible`** and the bootstrap log will **not** exist until you enable the option and **replace** the head instance, then Apply again.

#### 1. Prepare Stack Archive (manual upload)

Create a zip file containing all Terraform files:

```bash
# On Windows (PowerShell)
Compress-Archive -Path main.tf,variables.tf,outputs.tf,schema.yaml,scripts,inventory.tpl,playbooks -DestinationPath oci-hpc-bm-cluster-stack.zip

# On Linux/Mac
zip -r oci-hpc-bm-cluster-stack.zip main.tf variables.tf outputs.tf schema.yaml inventory.tpl playbooks/ scripts/
```

**Important**: Ensure the zip file contains:
- `main.tf`
- `variables.tf`
- `outputs.tf`
- `schema.yaml`
- `scripts/` directory (required when using Run Ansible from head; contains `head_bootstrap.sh.tpl`)
- `inventory.tpl` (optional, for Ansible)
- `playbooks/` directory (required when using Run Ansible from head; contains playbook and roles)

#### 2. Create Stack in OCI Resource Manager

1. Navigate to **OCI Console** ? **Resource Manager** ? **Stacks**
2. Click **Create Stack**
3. Select **Upload my Terraform configuration**
4. Upload `oci-hpc-bm-cluster-stack.zip`
5. Click **Next**

#### 3. Configure Stack Variables

**Required Variables** (in the Console):
- **Tenancy OCID** and **Region** are pre-filled from your session; you usually don?t need to change them.
- **Compartment**: Where to create resources (dropdown filtered by tenancy).
- **SSH Public Key**: For instance access.
- **RHEL 8.8 Image**: Image for BM and head node (dropdown filtered by compartment).

**Optional Network Variables**:
- `use_existing_vcn`: Set to `true` to use existing VCN (default: `false`)
- `existing_vcn_id`, `existing_public_subnet_id`, `existing_private_subnet_id`: When using existing VCN

#### 4. Review and Apply

1. Review the configuration
2. Click **Create** to create the stack
3. Click **Plan** to validate the configuration
4. Review the plan output
5. Click **Apply** to deploy the cluster

#### 5. Monitor Deployment

Monitor the job in **Resource Manager** ? **Jobs**:
- **Terraform Phase** (~15-30 minutes):
  - Create VCN and networking (if `use_existing_vcn = false`)
  - Provision head node (VM.Standard.E6.Flex)
  - Provision cluster network with 4 BM.Optimized3.36 nodes (RDMA)
  - Configure networking and security

### Option 2: Deploy with Terraform CLI

This stack is intended for **OCI Resource Manager** only. Deploy via the Console or the Deploy to Oracle Cloud button. The stack uses the resource principal; no API keys are required.

## Post-Deployment

### Accessing Your Cluster

After deployment, you can access the cluster:

1. **Head Node** (via public IP):
   ```bash
   ssh opc@<head_node_public_ip>
   ```
   The public IP is available in Terraform outputs.

2. **BM Nodes** (via private IP, through head node; RHEL images typically use **`cloud-user`**):
   ```bash
   # From head node
   ssh cloud-user@<bm_node_private_ip>
   ```
   Private IPs are available in Terraform outputs.

### Terraform Outputs

After deployment, Terraform provides:
- `created_vcn_id`: VCN OCID (created or existing)
- `head_node_public_ip`: Public IP of the head node
- `bm_node_private_ips`: List of private IPs for BM cluster network nodes
- `cluster_network_id`: Cluster network OCID (RDMA)
- `instance_pool_id`: Instance pool OCID for the BM cluster
- `existing_vcns_in_compartment`: Helper output listing existing VCNs

### Run Ansible from head node (Resource Manager)

If you set **Run Ansible from head at first boot** to **Yes** / true in the stack, the head node runs the RHEL + RDMA playbook automatically at first boot. Terraform embeds **BM private IPs** (and OCIDs) in bootstrap `user_data`; the OCI CLI on the head uses **instance principal** if it must resolve VNICs (no API keys on disk).

**Requirement:** Put the head node in a **dynamic group** and grant that group permission so the OCI CLI can use **instance principal**. The bootstrap script sets `OCI_CLI_AUTH=instance_principal` and writes `~/.oci/config` with `auth=instance_principal`, `region`, and `tenancy` so `oci` commands work from the head (including manual runs). You must create the dynamic group and policies **before** (or right after) the stack runs, then re-run the bootstrap if it had already failed.

1. **Create a dynamic group** (same idea as [oci-hpc](https://github.com/oracle-quickstart/oci-hpc)):  
   - **Name**: e.g. `instance_principal` or `hpc-head-instances`  
   - **Matching rule** (use your compartment OCID from the stack):
     ```
     Any { instance.compartment.id = 'ocid1.compartment.oc1..aaaaaaaa...' }
     ```
     That matches all compute instances in that compartment. You can narrow later (e.g. by tag) if needed.

2. **Create a policy** in the compartment (or tenancy) so the dynamic group can list instance pools and VNICs:
   ```
   Allow dynamic-group instance_principal to manage compute-management-family in compartment <compartment_name>
   Allow dynamic-group instance_principal to read instance-family in compartment <compartment_name>
   Allow dynamic-group instance_principal to use virtual-network-family in compartment <compartment_name>
   ```
   Or a single broad policy (as in oci-hpc):
   ```
   Allow dynamic-group instance_principal to manage all-resources in compartment <compartment_name>
   ```
   Use the same dynamic group name as in step 1.

3. **Apply the stack** with `run_ansible_from_head = true`, `rhsm_username`, and `rhsm_password` set. After the head node boots, check `/var/log/oci-hpc-ansible-bootstrap.log` on the head node for playbook progress.

**Note:** Aligned with [oracle-quickstart/oci-hpc](https://github.com/oracle-quickstart/oci-hpc) **data.tf**: BM instance IDs come from **`oci_core_cluster_network_instances`** plus one **`oci_core_instance`** data source per node. After the cluster network reaches **RUNNING**, Terraform waits **`bm_pool_ready_wait`** (default **10m**), then reads IDs and (when enabled) injects private IPs into the bootstrap script. user_data is **cloud-init**; Ansible runs on the head at first boot. Log: **`/var/log/oci-hpc-ansible-bootstrap.log`**. Set **SSH user for instances** to match your image (`cloud-user` for RHEL, `opc` for Oracle Linux).

**Why does provisioning take so long?** The stack creates a **cluster network** with **bare metal** nodes (BM.Optimized3.36). Terraform polls until OCI reports **RUNNING**. Default wait follows oci-hpc **`timeout_ip`**: `((bm_node_count - bm_node_count%20)/20 + 1) * 30` minutes unless **`cluster_network_create_timeout`** is set. Then **`bm_pool_ready_wait`**, then the **head VM** is created.

**Terraform never runs Ansible** ? it only creates the instance with user_data. The bootstrap runs **inside the VM at first boot** via cloud-init. So "Apply complete" in Terraform just means the instance was created; configuration happens asynchronously on the node.

#### Bootstrap didn't run ? diagnose on the head node

**No bootstrap log at all?** If `/var/log/oci-hpc-ansible-bootstrap.log` and `/opt/oci-hpc-bootstrap.sh` don't exist, the head was created with **"Run Ansible from head" = No** / `run_ansible_from_head = false`, or the head predates enabling it. Enable it in the stack (or `terraform.tfvars`) and **replace the head instance** so new `user_data` runs on first boot: `terraform apply -replace=oci_core_instance.head_node`. The wizard default is now **Yes**; existing stacks may still have the old default until you edit variables.

SSH to the head node (`ssh opc@<head_node_public_ip>` or `cloud-user@...`), then run:

```bash
# 1) Did cloud-init run and write the script?
ls -la /opt/oci-hpc-bootstrap.sh
# If missing, user_data wasn't applied (run_ansible_from_head was false) or cloud-init didn't run write_files.

# 2) Cloud-init logs (look for runcmd, write_files, errors)
sudo tail -100 /var/log/cloud-init-output.log
sudo grep -i error /var/log/cloud-init.log

# 3) Bootstrap log (if the script ran at all)
sudo cat /var/log/oci-hpc-ansible-bootstrap.log
# If empty or missing, the script didn't run or failed before logging.

# 4) Run the bootstrap manually (after fixing dynamic group / instance principal if needed)
sudo /opt/oci-hpc-bootstrap.sh
# Then: sudo tail -f /var/log/oci-hpc-ansible-bootstrap.log
```

If `/opt/oci-hpc-bootstrap.sh` is missing, the image may not be running cloud-init on user_data (e.g. wrong format or cloud-init not enabled). If the script exists but the log is empty, run it manually as above and watch the log for errors (e.g. OCI CLI auth failure = dynamic group not set).

#### Post-deploy checklist (head node)

SSH to the head node (`ssh opc@<head_node_public_ip>` or `cloud-user@...`) and run through this list. If `/etc/hosts` is not updated, the checklist will show where things stopped.

| # | Check | Command | What you want to see |
|---|--------|--------|----------------------|
| 1 | Bootstrap log exists | `ls -la /var/log/oci-hpc-ansible-bootstrap.log` | File exists and has non-zero size |
| 2 | Bootstrap reached Ansible | `sudo grep -E "Bootstrap: Ansible|Bootstrap: done|\+[0-9]+ BM" /var/log/oci-hpc-ansible-bootstrap.log` | Lines like `Bootstrap: Ansible...`, `Bootstrap: done`, and `+4 BM (TF)` or `+4 BM` |
| 3 | BM hosts in inventory | `cat /opt/oci-hpc-ansible/inventory/hosts` | `[head]` with `head-node` and `[bm]` with `bm-node-1` ? `bm-node-4` (each with `ansible_host=<ip>`) |
| 4 | `/etc/hosts` has cluster entries | `cat /etc/hosts` | Lines for `head-node`, `headnode`, `bm-node-1` ? `bm-node-4` with their IPs (not only localhost and cloud-init hostname) |
| 5 | Passwordless SSH to a BM node | `ssh -o BatchMode=yes -o ConnectTimeout=5 cloud-user@bm-node-1 hostname` | Prints hostname without password prompt (use `opc@bm-node-1` if BM image is Oracle Linux) |
| 6 | (Optional) RDMA play ran | `sudo grep -E "RDMA|no hosts matched|skipping" /var/log/oci-hpc-ansible-bootstrap.log` | No ?skipping: no hosts matched? for the RDMA play if you want RDMA configured |

**If `/etc/hosts` has no cluster entries:** Check (2) and (3). If (2) shows `Bootstrap: done` but (3) has an empty `[bm]` section, Terraform did not inject BM IPs (or they were null); check the log for `Bootstrap: wait pool` and `+N BM`. If (3) looks correct but (4) does not, the playbook likely failed during gather_facts (e.g. SSH to BM nodes). Re-run it manually (below); the playbook now updates /etc/hosts on the head first so bm-node-* resolve before SSH.

**Re-run the playbook manually (from head node):**
```bash
cd /opt/oci-hpc-ansible
sudo ansible-playbook -i inventory/hosts configure-rhel-rdma.yml -e @extra_vars.yml
```
Then check `/etc/hosts` and run step 5 to verify SSH.

**Can't SSH to the head node (Permission denied):** The **SSH Public Key** in the stack must exactly match the public key for the private key you use to connect. From your machine run: `ssh-keygen -y -f /path/to/your-private.key` and compare the output (one line) with what you pasted in the stack variable?no extra spaces or line breaks. Use user **opc** for Oracle Linux: `ssh -i /path/to/your-private.key opc@<head_public_ip>`. The stack also adds a Terraform-generated key so both your key and the generated key are on the head.

**"Permission denied (publickey)" when Ansible connects to BM nodes:** Confirm BMs received the **Terraform-generated** public key in instance metadata (re-apply if the instance configuration changed). The bootstrap should install `/root/.ssh/id_ed25519` (and the head user's copy). Re-run **`sudo /opt/oci-hpc-bootstrap.sh`** after fixes, or run the playbook from your laptop with your own key.

**"Host key verification failed" when SSHing to bm-node-1:** Either bm-node-1 is not in `/etc/hosts` yet, or the BM host key is not in `~/.ssh/known_hosts`. Re-run the playbook to populate `/etc/hosts`; then from the head run once: `ssh -o StrictHostKeyChecking=accept-new cloud-user@bm-node-1 hostname` (or `opc@bm-node-1` for Oracle Linux BM).

**See why the playbook didn?t update `/etc/hosts`:** Check for Ansible failures in the log:
```bash
sudo grep -E "FAILED|fatal|unreachable|TF BM|\\+[0-9]+ BM" /var/log/oci-hpc-ansible-bootstrap.log
```
If you see `+0 BM (TF)` or `+0 BM` and `WARN [bm] empty`, the inventory had no BM hosts (Terraform passed no IPs or OCI CLI returned none). Compare stack output `bm_node_private_ips` with `cat /opt/oci-hpc-ansible/inventory/hosts` to confirm IPs match.

**Quick checks (copy-paste on head):**
```bash
# 1?4 in one go
ls -la /var/log/oci-hpc-ansible-bootstrap.log
sudo tail -50 /var/log/oci-hpc-ansible-bootstrap.log | grep -E "Bootstrap:|Ansible|BM|done"
cat /opt/oci-hpc-ansible/inventory/hosts
cat /etc/hosts
```

**Why `/etc/hosts` has no cluster entries:** With **Run Ansible from head** enabled, Terraform injects BM IPs into the bootstrap; the script builds the inventory from that and then runs Ansible. If the inventory at `/opt/oci-hpc-ansible/inventory/hosts` has no `[bm]` hosts, either Terraform had no instances yet (wait was too short) or the script failed before writing the file. If the inventory is correct but `/etc/hosts` is not updated, the playbook failed on the head (e.g. SSH to BM nodes). Re-run the playbook manually (see above) or run `sudo /opt/oci-hpc-bootstrap.sh` again after fixing SSH/connectivity.

**RDMA play skipped ("no hosts matched"):** The RDMA play runs only on the `[bm]` group. If the log shows "skipping: no hosts matched" for that play, the inventory had no BM hosts?usually because OCI `list-vnics` didn?t return private IPs yet. The bootstrap now retries and falls back to the first VNIC?s IP; check the log for "added N BM hosts to inventory". If N is 0, the bootstrap could not get private IPs (e.g. dynamic group needs permission to list VNICs). Fix the dynamic group, then re-apply or re-run the bootstrap. To debug: on the head run `oci compute instance list-vnics --instance-id <id> --compartment-id <id> --all` and confirm the JSON has a data array with private IP fields.

**"environment: line N: No such file or directory":** These messages often come from the OS or OCI CLI environment (e.g. sourcing `/etc/environment`) and can be ignored; the bootstrap does not depend on them.

**"timeout while waiting for state to become 'RUNNING'" on `oci_core_cluster_network.bm_cluster`:** Provisioning exceeded the create timeout (default: oci-hpc formula above; override with **`cluster_network_create_timeout`**). **Re-apply** once the cluster network is **RUNNING** in the Console so Terraform can continue to the head node and Ansible. Increase **`cluster_network_create_timeout`** (e.g. `90m`, `2h`) if needed.

**More verbose Terraform logs during apply:** To see detailed provider API calls and polling, run Terraform with `TF_LOG=DEBUG` (e.g. in a local run: `TF_LOG=DEBUG terraform apply`). In Resource Manager you don?t control this; the apply log already shows "Still creating... [Xm elapsed]" for long-running resources. The cluster network state is reported in the error message ("last state: 'PROVISIONING'").

### Running the RHEL + RDMA Ansible playbook (manual)

Alternatively, after the stack has applied you can run the Ansible playbook yourself from a machine that can SSH to the head node.

1. **Build an inventory** from stack outputs:
   - Copy `playbooks/inventory/hosts.sample` to `playbooks/inventory/hosts.yml`.
   - Set `HEAD_NODE_PUBLIC_IP` to the stack output `head_node_public_ip`.
   - Set `BM_PRIVATE_IP_1` ? `BM_PRIVATE_IP_4` to the IPs from `bm_node_private_ips` (in order).

2. **Run the playbook** (from a machine that can SSH to the head node; the head node can then reach BM nodes via private IPs):
   ```bash
   cd playbooks
   ansible-playbook -i inventory/hosts.yml configure-rhel-rdma.yml \
     -e "rhsm_username=YOUR_RHSM_USER" -e "rhsm_password=YOUR_RHSM_PASS" \
     -e "rdma_ping_target=10.0.3.2" \
     --ask-become-pass
   ```
   - `rdma_ping_target`: Use another BM node?s **RDMA (secondary VNIC)** IP, e.g. from the `10.0.3.0/24` range if you created a new VCN.
   - For RHEL registration you must pass `rhsm_username` and `rhsm_password`.

3. **Optional**: Use Ansible Vault for secrets:
   ```bash
   ansible-vault create group_vars/all/vault.yml  # add rhsm_username, rhsm_password
   ansible-playbook -i inventory/hosts.yml configure-rhel-rdma.yml --ask-vault-pass
   ```

The playbook runs **rhel_prep** on all nodes (head + BM) and **rdma_auth** on BM nodes only.

## File Structure

```
kove-oci-build-2/
??? main.tf                    # Main Terraform configuration
?                              # - Provider configuration
?                              # - VCN and networking resources
?                              # - Head node instance
?                              # - BM node instances
??? variables.tf                # Terraform variable definitions
??? outputs.tf                  # Terraform outputs
??? schema.yaml                 # OCI Resource Manager stack UI schema
??? scripts/
?   ??? head_bootstrap.sh.tpl           # Bootstrap script (written to /opt by cloud-init)
?   ??? cloud_init_head.yaml.tpl       # Cloud-config: ssh-rsa + optional bootstrap + runcmd
??? inventory.tpl               # Ansible inventory template (full HPC stack)
??? playbooks/
    ??? configure-rhel-rdma.yml # RHEL + RDMA config (run after stack apply)
    ??? inventory/
    ?   ??? hosts.sample        # Sample inventory; fill from stack outputs
    ??? site.yml                # Full HPC stack playbook (optional)
    ??? roles/
        ??? rhel_prep/          # RHEL registration and prep
        ?   ??? tasks/main.yml
        ??? rdma_auth/          # RDMA authentication setup
            ??? tasks/main.yml
```

## Ansible Roles

The project includes two Ansible roles that can be used independently:

### `rhel_prep` Role

**Purpose**: Prepares RHEL nodes for HPC workloads

**Tasks**:
- Sets hostname pattern (requires `bm_prefix` variable)
- Registers with Red Hat Subscription Manager (idempotent)
- Pins RHEL release to 8.8
- Enables RHEL repositories (BaseOS, AppStream)
- Installs toolchain (python3, policycoreutils-python-utils, environment-modules)
- Installs RDMA libraries and utilities
- Installs OpenMPI
- Configures environment modules in `.bashrc`

**Required Variables**:
- `rhsm_username`: Red Hat Subscription Manager username
- `rhsm_password`: Red Hat Subscription Manager password
- `bm_prefix`: Hostname prefix for BM nodes (e.g., "node-")

### `rdma_auth` Role

**Purpose**: Configures RDMA authentication for OCI cluster networks

**Tasks**:
- Installs NetworkManager cloud setup
- Configures `nm-cloud-setup` for OCI
- Sets SELinux context for RDMA auth
- Installs `oci-cn-auth` RPM
- Performs initial RDMA authentication
- Creates automated re-authentication system (every 105 minutes)
- Performs RDMA connectivity test

**Required Variables**:
- `rdma_interface`: RDMA interface name (e.g., "eth2")
- `rdma_ping_target`: IP address for RDMA ping test
- `oci_cn_auth_rpm_url`: URL or package name for oci-cn-auth RPM

**Note**: These roles are available but not automatically executed by the current `site.yml` playbook, which is configured for a full HPC stack. You can create a custom playbook to use these roles.

## Troubleshooting

### Terraform Errors

**Cluster network creation fails quickly with state `TERMINATED` (not `RUNNING`)**

Common causes:

1. **Wrong availability domain** ? `BM.Optimized3.36` fleet hardware exists only in specific ADs per region. The stack defaults to the **first AD** returned for the tenancy; in Phoenix and other regions that may not support this shape's cluster network. Set **`cluster_network_availability_domain`** to an AD that supports cluster networks (Console: create flow or capacity report; name looks like `Uocm:PHX-AD-1`).
2. **Placement networking** ? Do **not** set `secondary_vnic_subnets` for this shape; OCI returns **`400-InvalidParameter`** (*There should be 0 secondaryVnicsSubnets specified*). Use **`primary_vnic_subnets`** only (private subnet), matching [oci-hpc](https://github.com/oracle-quickstart/oci-hpc) cluster network placement.
3. **Instance configuration** ? The template uses **`source = "NONE"`** (oci-hpc style), explicit **boot volume** size, **OS Management Service Agent** disabled, and **RDMA** plugins enabled. A **custom image** must still be **compatible** with `BM.Optimized3.36` and cluster networking; see OCI work request / service logs in the Console for the exact error.
4. **Image** ? Oracle's docs often reference the **Oracle Linux HPC** marketplace image for cluster networks; custom **RHEL** images can work but must meet OCI requirements for BM + RDMA.

**Error: 400 - CannotParseRequest**
- **Cause**: Instance configuration may have incorrect structure
- **Solution**: Ensure `create_vnic_details` is NOT in instance configuration (cluster networks handle VNICs automatically)

**Error: Missing required argument**
- **Cause**: Missing `compartment_id` in data sources
- **Solution**: Verify all required variables are provided

### Ansible Errors

**RHEL Registration Fails**
- **Cause**: Invalid RHSM credentials
- **Solution**: Verify username/password in stack variables

**RDMA Authentication Fails**
- **Cause**: NetworkManager or oci-cn-auth not properly configured
- **Solution**: Check logs: `journalctl -u oci-cn-auth.service`

### Network Issues

**Nodes Can't Communicate**
- **Cause**: Security list rules not configured
- **Solution**: If using existing VCN, ensure security list allows all traffic within VCN CIDR

**No Internet Access**
- **Cause**: NAT Gateway or route table not configured
- **Solution**: If using existing VCN, ensure private subnet has route to NAT Gateway

## Customization

### Changing Node Count

Edit the `count` parameter in `main.tf` for the `oci_core_instance.bm_nodes` resource (currently set to 4).

### Using Different BM Shape

Modify the `shape` parameter in `main.tf` for the `oci_core_instance.bm_nodes` resource. Supported shapes:
- `BM.Optimized3.36` (current)
- Other BM shapes as available in your region

## Limitations

- **Fixed Node Count**: Currently hardcoded to 4 BM nodes. Edit `main.tf` to change.
- **Fixed Head Node Shape**: Head node is VM.Standard.E6.Flex with 1 OCPU/8GB RAM. Edit `main.tf` to change.
- **Ansible Playbooks**: The included playbooks are for a full HPC stack and may require customization for your needs.

## Support

For issues or questions:
1. Check the troubleshooting section above
2. Review OCI Resource Manager job logs (if using Resource Manager)
3. Check the stack job logs in Resource Manager
4. Review Terraform state for resource status
5. Check instance console logs in OCI Console

## License

This stack is based on the Oracle Quickstart OCI HPC Stack and follows similar licensing terms.

## References

- [OCI HPC Documentation](https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/hpc-cluster-network.htm)
- [OCI Resource Manager](https://docs.oracle.com/en-us/iaas/Content/ResourceManager/Concepts/resourcemanager.htm)
- [RDMA on OCI](https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/hpc-rdma.htm)
