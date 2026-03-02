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
- `main` – branch name (use `master` if that's your default)

When clicked, this:
1. Downloads `https://github.com/YOUR_USERNAME/YOUR_REPO/archive/refs/heads/main.zip`
2. Opens OCI Resource Manager "Create Stack" with that zip pre-loaded
3. Shows the UI defined by your `schema.yaml`

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

## Testing Locally

Before pushing, test with Terraform CLI:

```bash
terraform init
terraform plan -var-file=test.tfvars
```

Create `test.tfvars` (don't commit):
```hcl
tenancy_ocid     = "ocid1.tenancy.oc1..xxx"
region           = "us-ashburn-1"
compartment_ocid = "ocid1.compartment.oc1..xxx"
ssh_public_key   = "ssh-rsa AAAA..."
```

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
├── README.md              # With deploy button
├── main.tf                # Main Terraform config
├── variables.tf           # Variable definitions
├── outputs.tf             # Output definitions
├── schema.yaml            # Resource Manager UI schema
├── scripts/
│   ├── cloud_init.yaml.tpl
│   └── bootstrap.sh.tpl
└── .gitignore             # Ignore .terraform/, *.tfstate, test.tfvars
```

## References

- [OCI Resource Manager Documentation](https://docs.oracle.com/en-us/iaas/Content/ResourceManager/Concepts/resourcemanager.htm)
- [Schema Document Reference](https://docs.oracle.com/en-us/iaas/Content/ResourceManager/Concepts/terraformconfigresourcemanager_topic-schema.htm)
- [Terraform OCI Provider](https://registry.terraform.io/providers/oracle/oci/latest/docs)
- [Deploy Button Guide](https://docs.oracle.com/en-us/iaas/Content/ResourceManager/Tasks/deploybutton.htm)
