# OCI Resource Manager "Deploy to Oracle Cloud" Guide

This guide explains how to set up a Terraform project for one-click deployment via OCI Resource Manager using the "Deploy to Oracle Cloud" button.

## Overview

OCI Resource Manager lets users deploy Terraform stacks directly from a GitHub repo URL. When a user clicks the button, Resource Manager downloads your repo as a zip, creates a stack, and presents a UI for variables defined in `schema.yaml`.

## Required Files

Your repo needs these files at the root (or in a subdirectory if you adjust the URL):

| File | Purpose |
|------|---------|
| `main.tf` | Main Terraform configuration |
| `variables.tf` | Variable definitions |
| `outputs.tf` | Output definitions |
| `schema.yaml` | **Required for Resource Manager UI** – defines variable groups, types, and display in the OCI Console |

Optional but recommended:
- `README.md` – Documentation with the deploy button
- `scripts/` – Bootstrap scripts (if using cloud-init)
- `playbooks/` – Ansible playbooks (if applicable)

## The Deploy Button

Add this to your `README.md`:

```markdown
[![Deploy to Oracle Cloud](https://oci-resourcemanager-plugin.plugins.oci.oraclecloud.com/latest/deploy-to-oracle-cloud.svg)](https://cloud.oracle.com/resourcemanager/stacks/create?zipUrl=https://github.com/YOUR_USERNAME/YOUR_REPO/archive/refs/heads/main.zip)
```

Replace:
- `YOUR_USERNAME` – your GitHub username or org
- `YOUR_REPO` – repository name
- `main` – branch name (use `master` if that's your default), **or** use a **tag** for a stable, named snapshot, e.g. `https://github.com/YOUR_USERNAME/YOUR_REPO/archive/refs/tags/Kove-RHEL88-OCI.zip` (this repo’s deploy button uses tag **`Kove-RHEL88-OCI`** instead of `master`).

When clicked, this:
1. Downloads the archive from the `zipUrl` you set (branch or tag)
2. Opens OCI Resource Manager "Create Stack" with that zip pre-loaded
3. Shows the UI defined by your `schema.yaml`

### When the console UI does not match the latest `schema.yaml`

Resource Manager **snapshots the Terraform zip** when you create a stack. **Pushing to GitHub does not update stacks that already exist.** If you still see old variables (for example advanced BM or agent options) after changing `schema.yaml`:

1. **Create a new stack** from an up-to-date zip (use **Deploy to Oracle Cloud** again, or **Upload** a zip you built from the current repo), **or**
2. Open the existing stack → **Edit** → replace or re-upload the **Terraform configuration** so the stack uses a zip that contains the new `schema.yaml` (wording varies slightly by console version).

If you deploy from a **Git tag** zip URL, remember the archive is whatever commit the tag points to; move the tag (or use a new tag) and push so the button downloads a build that includes your UI changes.

## schema.yaml Structure

This file defines how variables appear in the OCI Console UI.

### Minimal Example

```yaml
title: "My Stack"
description: "Deploy resources to OCI."
schemaVersion: 1.1.0
version: "20190304"
locale: "en"

variableGroups:
  - title: "Required Configuration"
    variables:
      - compartment_ocid
      - ssh_public_key

  - title: "Optional Configuration"
    variables:
      - instance_count

  - title: "Hidden (auto-filled)"
    variables:
      - tenancy_ocid
      - region

variables:
  tenancy_ocid:
    type: string
    title: "Tenancy OCID"
    description: "Auto-filled from your session."
    required: true

  region:
    type: oci:identity:region:name
    title: "Region"
    description: "Auto-filled from your session."
    required: true

  compartment_ocid:
    type: oci:identity:compartment:id
    title: "Compartment"
    description: "Where to create resources."
    required: true
    dependsOn:
      compartmentId: ${tenancy_ocid}

  ssh_public_key:
    type: oci:core:ssh:publickey
    title: "SSH Public Key"
    description: "Public key for instance access."
    required: true

  instance_count:
    type: number
    title: "Instance Count"
    description: "Number of instances to create."
    default: 1
    minimum: 1
    maximum: 10
    required: false

outputs:
  instance_public_ip:
    title: "Instance Public IP"
    visible: true
```

### Common Variable Types

| Type | Description | Example |
|------|-------------|---------|
| `string` | Plain text input | Names, OCIDs, keys |
| `number` | Numeric input | Counts, sizes |
| `boolean` | Checkbox (true/false) | Feature toggles |
| `password` | Masked text input | Secrets |
| `oci:identity:compartment:id` | Compartment picker | Target compartment |
| `oci:identity:region:name` | Region picker | Target region |
| `oci:core:ssh:publickey` | SSH key input | Instance SSH key |
| `oci:core:image:id` | Image picker | OS image |
| `oci:core:vcn:id` | VCN picker | Existing VCN |
| `oci:core:subnet:id` | Subnet picker | Existing subnet |
| `enum` | Dropdown selection | Fixed choices |

### Variable with Dependencies (Picker Scoping)

```yaml
compartment_ocid:
  type: oci:identity:compartment:id
  title: "Compartment"
  required: true
  dependsOn:
    compartmentId: ${tenancy_ocid}

# Image picker scoped to the selected compartment
image_ocid:
  type: oci:core:image:id
  title: "OS Image"
  required: true
  dependsOn:
    compartmentId: ${compartment_ocid}

# Subnet picker scoped to a VCN
subnet_id:
  type: oci:core:subnet:id
  title: "Subnet"
  required: false
  dependsOn:
    compartmentId: ${compartment_ocid}
    vcnId: ${vcn_id}
```

### Enum (Dropdown)

```yaml
instance_shape:
  type: enum
  title: "Instance Shape"
  description: "Compute shape for instances."
  default: "VM.Standard.E4.Flex"
  enum:
    - "VM.Standard.E4.Flex"
    - "VM.Standard.E5.Flex"
    - "VM.Standard3.Flex"
  required: true
```

### Conditional Visibility

```yaml
use_existing_vcn:
  type: boolean
  title: "Use Existing VCN"
  default: false

existing_vcn_id:
  type: oci:core:vcn:id
  title: "Existing VCN"
  required: false
  visible:
    eq:
      - ${use_existing_vcn}
      - true
  dependsOn:
    compartmentId: ${compartment_ocid}
```

### Outputs

```yaml
outputs:
  instance_ip:
    title: "Instance IP"
    visible: true

  connection_string:
    title: "SSH Command"
    visible: true
```

## variables.tf Must Match schema.yaml

Every variable in `schema.yaml` must exist in `variables.tf`:

```hcl
variable "tenancy_ocid" {
  type        = string
  description = "Tenancy OCID"
}

variable "region" {
  type        = string
  description = "OCI region"
}

variable "compartment_ocid" {
  type        = string
  description = "Compartment OCID"
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key"
}

variable "instance_count" {
  type        = number
  description = "Number of instances"
  default     = 1
}
```

## outputs.tf

```hcl
output "instance_public_ip" {
  description = "Public IP of the instance"
  value       = oci_core_instance.this.public_ip
}
```

## Cloud-Init Bootstrap (Optional)

To run a script on first boot:

### 1. Create a cloud-init template

`scripts/cloud_init.yaml.tpl`:
```yaml
#cloud-config
write_files:
  - path: /opt/bootstrap.sh
    permissions: '0755'
    encoding: b64
    content: ${bootstrap_script_b64}

runcmd:
  - /opt/bootstrap.sh
```

### 2. Create the bootstrap script template

`scripts/bootstrap.sh.tpl`:
```bash
#!/bin/bash
set -e
LOG=/var/log/bootstrap.log
echo "$(date) Starting bootstrap" | tee -a "$LOG"

# Use template variables
MESSAGE="${message}"
echo "$MESSAGE" >> "$LOG"

# Install packages, configure services, etc.
dnf install -y jq || yum install -y jq

echo "$(date) Bootstrap complete" >> "$LOG"
```

### 3. Use in main.tf

```hcl
locals {
  bootstrap_vars = {
    message = "Hello from Terraform"
  }
}

resource "oci_core_instance" "this" {
  # ... other config ...

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data = base64encode(templatefile(
      "${path.module}/scripts/cloud_init.yaml.tpl",
      {
        bootstrap_script_b64 = base64encode(templatefile(
          "${path.module}/scripts/bootstrap.sh.tpl",
          local.bootstrap_vars
        ))
      }
    ))
  }
}
```

## Metadata Size Limit

OCI has a **32KB limit** for `user_data`. If your bootstrap is large:

1. **Compress payloads** – Use `data "archive_file"` to zip files, then base64 encode
2. **Shorten scripts** – Remove comments, use short variable names
3. **External download** – Store large files in Object Storage and download at boot

Example with archive:
```hcl
data "archive_file" "scripts" {
  type        = "zip"
  source_dir  = "${path.module}/scripts"
  output_path = "${path.module}/.terraform/scripts.zip"
}

locals {
  scripts_b64 = filebase64(data.archive_file.scripts.output_path)
}
```

## Instance Principal for OCI CLI on Instances

If your bootstrap needs to call OCI APIs (e.g., list instances):

### 1. Create a Dynamic Group

```
ALL {instance.compartment.id = '<compartment_ocid>'}
```
Or match by tag/display name.

### 2. Create a Policy

```
Allow dynamic-group <group_name> to read all-resources in compartment <compartment_name>
```

### 3. Use in bootstrap script

```bash
export OCI_CLI_AUTH=instance_principal
oci compute instance list --compartment-id "$COMPARTMENT_ID" --all
```

Write a minimal `~/.oci/config`:
```bash
mkdir -p ~/.oci
cat > ~/.oci/config << 'EOF'
[DEFAULT]
auth=instance_principal
region=us-ashburn-1
tenancy=ocid1.tenancy.oc1..xxx
EOF
chmod 600 ~/.oci/config
```

## Sensitive Variables

For secrets (passwords, private keys):

### variables.tf
```hcl
variable "my_secret" {
  type        = string
  description = "A secret value"
  sensitive   = true
  default     = ""
}
```

### schema.yaml
```yaml
my_secret:
  type: password
  title: "Secret"
  description: "Enter a secret value."
  required: false
```

**Note:** Sensitive values are stored in Terraform state. Use dedicated credentials and restrict state access.

## Testing locally from your desktop (Windows)

Use the **same Terraform** as Resource Manager, but run **`terraform`** on your PC. You **do not** deploy the stack with OCI CLI alone — OCI CLI is only for **creating API-key auth** that the Terraform provider reads.

### 1. Install Terraform

Pick one:

- **winget:** `winget install Hashicorp.Terraform`
- **Chocolatey:** `choco install terraform`
- Or download a zip from [Terraform installs](https://developer.hashicorp.com/terraform/install), extract, and add the folder to your **PATH**.

Verify:

```powershell
terraform version
```

### 2. Install OCI CLI (for API key auth)

- Follow [Installing the CLI (Windows)](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm#Installing_2).
- Or **winget:** `winget install Oracle.OciCLI`

Verify:

```powershell
oci --version
```

### 3. Create an API key and config profile

1. In **OCI Console** → your user → **API keys** → **Add API key** → generate or upload a key pair. Save the private key (e.g. `C:\Users\<you>\.oci\oci_api_key.pem`).
2. Run the interactive wizard:

```powershell
oci setup config
```

Answer prompts for tenancy OCID, user OCID, region, and path to the private key. This creates **`%USERPROFILE%\.oci\config`** (default profile **`DEFAULT`**).

The **Terraform OCI provider** uses this file automatically when you are **not** inside Resource Manager (which uses **resource principal** instead).

### 4. IAM

The **same user** as the API key needs policies to manage resources in your test compartment (VCN, compute, etc.), similar to what you use for Resource Manager.

### 5. Clone the stack and point at your var-files

```powershell
cd C:\path\to\your\work
git clone https://github.com/ncusato/kove-terraform-oci.git
cd kove-terraform-oci
```

Keep your variable files **outside the repo** (e.g. under **Downloads**) so they are never committed. Use **HCL syntax** inside the files; the **`.txt`** extension is fine — Terraform reads them when you pass **`-var-file`**.

**Example paths (adjust if you move the files):**

| File | Purpose |
|------|--------|
| `C:\Users\ncusato\Downloads\kove-terraform.tfvars.txt` | Tenancy, region, compartment, subnets, `ssh_public_key`, flags, etc. |
| `C:\Users\ncusato\Downloads\secrets.auto.tfvars.txt` | RHSM username/password when **Run Ansible from head** is true (optional otherwise) |

Create/edit them with Notepad or your editor. Copy from **`terraform.tfvars.example`** in the repo for the non-secret file shape. Head-run Ansible uses the Terraform-generated SSH key in bootstrap (no SSH private key variable).

**Important:** Files named `*.txt` in **Downloads** are **not** auto-loaded. You must pass **both** paths on every `plan` / `apply` / `destroy` (see below).

### 6. Initialize and run Terraform

From the **repo directory** (where `main.tf` is):

```powershell
terraform init

terraform plan `
  -var-file="C:\Users\ncusato\Downloads\kove-terraform.tfvars.txt" `
  -var-file="C:\Users\ncusato\Downloads\secrets.auto.tfvars.txt"

terraform apply `
  -var-file="C:\Users\ncusato\Downloads\kove-terraform.tfvars.txt" `
  -var-file="C:\Users\ncusato\Downloads\secrets.auto.tfvars.txt"
```

If you do **not** use secrets yet, you can omit the second `-var-file` or keep an empty/minimal `secrets.auto.tfvars.txt` (e.g. only `rhsm_username = ""` / `rhsm_password = ""`).

### 7. State and environments

- Default state file: **`terraform.tfstate`** in the repo folder (local only).
- **Resource Manager** keeps **separate** state per stack — local apply does **not** update an existing RM stack unless you [configure a remote backend](https://developer.hashicorp.com/terraform/language/settings/backends/configuration) and point both at it (advanced).
- Use a **dedicated test compartment** for desktop experiments so you do not collide with customer stacks.

### 8. Destroy (test only)

Use the **same** `-var-file` arguments as `apply`:

```powershell
terraform destroy `
  -var-file="C:\Users\ncusato\Downloads\kove-terraform.tfvars.txt" `
  -var-file="C:\Users\ncusato\Downloads\secrets.auto.tfvars.txt"
```

### 9. Specify config safely (OCI key, tenancy, passwords)

**Goal:** run `init` / `plan` / `apply` without putting secrets in Git, chat logs, or shell history.

#### OCI API private key (the `.pem` you already have)

- Keep the **private key only under** `%USERPROFILE%\.oci\` (or another folder **outside** the repo).
- **`oci setup config`** writes **`%USERPROFILE%\.oci\config`** with `key_file=...` pointing at that PEM. **Do not** copy the PEM into the Terraform project.
- The Terraform OCI provider reads **`~/.oci/config`** for API authentication. You do **not** put the API key material in `terraform.tfvars`.

#### Terraform variables (OCIDs vs real secrets)

- **Identifiers (still confidential for customers):** `tenancy_ocid`, `compartment_ocid`, subnet OCIDs, image OCIDs. Put them in a **local** file that is **never committed** (e.g. `terraform.tfvars`). Don’t paste them into public tickets or screenshots.
- **Secrets:** `rhsm_password`, and optionally `rhsm_username` (if you treat it as sensitive). Keep them out of shared copies of `terraform.tfvars`.

**Recommended split (files outside the repo):**

1. **`C:\Users\ncusato\Downloads\kove-terraform.tfvars.txt`** — OCIDs, region, flags, `ssh_public_key`; no RHSM passwords here.
2. **`C:\Users\ncusato\Downloads\secrets.auto.tfvars.txt`** — RHSM credentials when using Ansible from head.

Example `secrets.auto.tfvars.txt`:

```hcl
rhsm_username = "your-rhsm-user"
rhsm_password = "your-rhsm-pass"
```

Because these live outside the module folder and use a **`.txt`** extension, pass them explicitly:

```powershell
terraform plan `
  -var-file="C:\Users\ncusato\Downloads\kove-terraform.tfvars.txt" `
  -var-file="C:\Users\ncusato\Downloads\secrets.auto.tfvars.txt"
terraform apply `
  -var-file="C:\Users\ncusato\Downloads\kove-terraform.tfvars.txt" `
  -var-file="C:\Users\ncusato\Downloads\secrets.auto.tfvars.txt"
```

*(Alternatively: name files `terraform.tfvars` and `secrets.auto.tfvars` **inside** the repo folder — Terraform auto-loads those — but then rely on `.gitignore` and never commit them.)*

**Alternative — environment variables** (handy for automation; the values exist in that shell session):

```powershell
$env:TF_VAR_rhsm_password = (Get-Content -Raw C:\secure\rhsm_password.txt).Trim()
terraform plan
```

Use a file **outside the repo** that you never commit, or a private script you keep local only.

Avoid **`terraform apply -var="rhsm_password=..."`** — that often lands in **PowerShell command history**.

#### Files Terraform writes (also confidential)

- **`terraform.tfstate`** — may contain sensitive values; **gitignored**; do not share.
- **`crash.log`** — may include config snippets; redact before sharing.

#### Optional: var-files outside the repo

```powershell
terraform plan `
  -var-file="C:\Users\you\Documents\oci-stacks\kove.tfvars" `
  -var-file="C:\Users\you\Documents\oci-stacks\kove-secrets.auto.tfvars"
```

---

**Summary:** **Terraform CLI** runs the deployment. **OCI CLI** sets up **`~/.oci/config`** + API key so the provider can authenticate on your desktop. Use **gitignored** `terraform.tfvars` plus optional **`secrets.auto.tfvars`** (or `TF_VAR_*`) so tenancy details and passwords stay off Git and out of history where possible.

## Checklist Before Publishing

- [ ] `schema.yaml` exists and is valid YAML
- [ ] All variables in `schema.yaml` exist in `variables.tf`
- [ ] Required variables have `required: true` in schema
- [ ] Defaults in schema match defaults in variables.tf
- [ ] Deploy button URL points to correct repo/branch
- [ ] Tested locally with `terraform plan`
- [ ] README explains what the stack does and any prerequisites
- [ ] Sensitive variables marked as `sensitive = true` and use `type: password`

## Example Repo Structure

```
my-oci-stack/
├── README.md                  # With deploy button
├── main.tf
├── variables.tf
├── outputs.tf
├── schema.yaml
├── terraform.tfvars.example   # Optional: copy to terraform.tfvars for desktop testing
├── scripts/
│   ├── cloud_init.yaml.tpl
│   └── bootstrap.sh.tpl
└── .gitignore                 # Ignore .terraform/, *.tfstate, terraform.tfvars
```

## References

- [OCI Resource Manager Documentation](https://docs.oracle.com/en-us/iaas/Content/ResourceManager/Concepts/resourcemanager.htm)
- [Schema Document Reference](https://docs.oracle.com/en-us/iaas/Content/ResourceManager/Concepts/terraformconfigresourcemanager_topic-schema.htm)
- [Terraform OCI Provider](https://registry.terraform.io/providers/oracle/oci/latest/docs)
- [Deploy Button Guide](https://docs.oracle.com/en-us/iaas/Content/ResourceManager/Tasks/deploybutton.htm)
