terraform {
  required_version = ">= 1.3.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 5.0.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

# Terraform-generated SSH key for head->BM (oci-hpc pattern). ED25519 keeps user_data smaller.
resource "tls_private_key" "cluster_ssh" {
  algorithm = "ED25519"
}

provider "oci" {
  tenancy_ocid = var.tenancy_ocid
  region       = var.region
  # Resource Manager uses resource principal; no API key needed.
}

# -------------------------------------------------------------------
# Data sources
# -------------------------------------------------------------------

# Availability domains
data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

# When using an existing private subnet, read its AD so placement matches (wrong AD → 0 instances launched).
data "oci_core_subnet" "existing_private" {
  count     = var.use_existing_vcn ? 1 : 0
  subnet_id = var.existing_private_subnet_id
}

data "oci_core_subnet" "existing_public" {
  count     = var.use_existing_vcn ? 1 : 0
  subnet_id = var.existing_public_subnet_id
}

locals {
  # Use the first AD by default
  ad_name = data.oci_identity_availability_domains.ads.availability_domains[0].name
}

# Optional helper: list existing VCNs & Subnets in the compartment
# (useful when you want to plug in existing IDs)
data "oci_core_vcns" "existing_vcns" {
  compartment_id = var.compartment_ocid
}

# Latest Oracle Linux 8 image for head node (used when head_node_image_ocid is empty)
data "oci_core_images" "ol8_head" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Oracle Linux"
  operating_system_version = "8"
  shape                    = "VM.Standard.E6.Flex"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

locals {
  # Extra CIDRs that may SSH to BM private IPs (bastion outside VCN, peering, etc.)
  private_subnet_ssh_extra_cidrs = compact([for s in split(",", var.private_subnet_ssh_sources_extras) : trimspace(s) if trimspace(s) != ""])
  public_subnet_cidr             = cidrsubnet(var.vcn_cidr_block, 8, 1)
  private_subnet_cidr            = cidrsubnet(var.vcn_cidr_block, 8, 2)
  # Short on-box guide (kept small for OCI instance metadata 32 KiB limit)
  head_home_readme_markdown = <<-EOT
# Kove cluster (head node)

**SSH to BMs:** `ssh cloud-user@<BM_private_ip>` (use stack Outputs for IPs; user may be `opc` on some images).

**Passwordless SSH from this head:** Git repo `docs/HEAD-BM-SSH-README.md` or `scripts/setup_bm_passwordless_ssh.sh`.

**RDMA on a BM:** `sudo systemctl status oci-cn-auth-refresh.timer`. If missing: `cd /opt/oci-hpc-ansible` then `sudo /usr/local/bin/ansible-playbook -i inventory/hosts configure-rhel-rdma.yml --limit bm`.

**Bootstrap log:** `sudo tail -200 /var/log/oci-hpc-ansible-bootstrap.log`
EOT

  custom_name_prefix_effective = trimspace(var.custom_name_prefix) != "" ? trimspace(var.custom_name_prefix) : trimspace(var.cluster_display_name_prefix)
  naming_prefix                = var.enable_custom_names ? local.custom_name_prefix_effective : "cluster"
  # Keep static defaults unless explicitly toggled on.
  vcn_name            = var.enable_custom_names ? "${local.naming_prefix}-vcn" : "cluster-vcn"
  igw_name            = var.enable_custom_names ? "${local.naming_prefix}-igw" : "cluster-igw"
  nat_name            = var.enable_custom_names ? "${local.naming_prefix}-nat" : "cluster-nat"
  public_rt_name      = var.enable_custom_names ? "${local.naming_prefix}-public-rt" : "cluster-public-rt"
  private_rt_name     = var.enable_custom_names ? "${local.naming_prefix}-private-rt" : "cluster-private-rt"
  public_sl_name      = var.enable_custom_names ? "${local.naming_prefix}-public-sl" : "cluster-public-sl"
  private_sl_name     = var.enable_custom_names ? "${local.naming_prefix}-private-sl" : "cluster-private-sl"
  public_subnet_name  = var.enable_custom_names ? "${local.naming_prefix}-public-subnet" : "cluster-public-subnet"
  private_subnet_name = var.enable_custom_names ? "${local.naming_prefix}-private-subnet" : "cluster-private-subnet"
  head_name           = var.enable_custom_names ? "${local.naming_prefix}-head-node" : "head-node"
  compute_cluster_name = var.enable_custom_names ? "${local.naming_prefix}-compute-cluster" : "compute-cluster"
  bm_name_prefix      = var.enable_custom_names ? "${local.naming_prefix}-bm" : "bm"
}

# -------------------------------------------------------------------
# Networking (optional create vs existing)
# -------------------------------------------------------------------

# Create VCN only when use_existing_vcn = false
resource "oci_core_virtual_network" "this" {
  count          = var.use_existing_vcn ? 0 : 1
  cidr_block     = var.vcn_cidr_block
  compartment_id = var.compartment_ocid
  display_name   = local.vcn_name
  # OCI VCN dns_label: alphanumeric, max 15 chars (sanitize prefix; avoid regex* functions for older TF quirks).
  dns_label = substr(
    length(trimspace(replace(replace(lower(local.naming_prefix), "-", ""), "_", ""))) > 0 ? replace(replace(lower(local.naming_prefix), "-", ""), "_", "") : "clustervcn",
    0,
    15
  )
}

resource "oci_core_internet_gateway" "this" {
  count          = var.use_existing_vcn ? 0 : 1
  compartment_id = var.compartment_ocid
  display_name   = local.igw_name
  enabled        = true
  vcn_id         = oci_core_virtual_network.this[0].id
}

resource "oci_core_nat_gateway" "this" {
  count          = var.use_existing_vcn ? 0 : 1
  compartment_id = var.compartment_ocid
  display_name   = local.nat_name
  vcn_id         = oci_core_virtual_network.this[0].id
}

resource "oci_core_route_table" "public" {
  count          = var.use_existing_vcn ? 0 : 1
  compartment_id = var.compartment_ocid
  display_name   = local.public_rt_name
  vcn_id         = oci_core_virtual_network.this[0].id

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.this[0].id
  }
}

resource "oci_core_route_table" "private" {
  count          = var.use_existing_vcn ? 0 : 1
  compartment_id = var.compartment_ocid
  display_name   = local.private_rt_name
  vcn_id         = oci_core_virtual_network.this[0].id

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.this[0].id
  }
}

# Public subnet SL — aligned with oracle-quickstart/oci-hpc public-security-list: intra-VCN + SSH from Internet + ICMP.
resource "oci_core_security_list" "public" {
  count          = var.use_existing_vcn ? 0 : 1
  compartment_id = var.compartment_ocid
  display_name   = local.public_sl_name
  vcn_id         = oci_core_virtual_network.this[0].id

  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }

  ingress_security_rules {
    protocol = "all"
    source   = var.vcn_cidr_block
  }

  ingress_security_rules {
    protocol = "6" # TCP
    source   = "0.0.0.0/0"

    tcp_options {
      min = 22
      max = 22
    }
  }

  ingress_security_rules {
    protocol = "1"
    source   = "0.0.0.0/0"

    icmp_options {
      type = 3
      code = 4
    }
  }

  ingress_security_rules {
    protocol = "1"
    source   = var.vcn_cidr_block

    icmp_options {
      type = 3
    }
  }

  ingress_security_rules {
    protocol = "1"
    source   = "0.0.0.0/0"

    icmp_options {
      type = 8
      code = 0
    }
  }
}

# Private subnet SL — oci-hpc internal-security-list pattern: full intra-VCN + ICMP path-MTU + optional extra SSH sources.
resource "oci_core_security_list" "private" {
  count          = var.use_existing_vcn ? 0 : 1
  compartment_id = var.compartment_ocid
  display_name   = local.private_sl_name
  vcn_id         = oci_core_virtual_network.this[0].id

  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }

  ingress_security_rules {
    protocol = "all"
    source   = var.vcn_cidr_block
  }

  dynamic "ingress_security_rules" {
    for_each = local.private_subnet_ssh_extra_cidrs
    content {
      protocol = "6"
      source   = ingress_security_rules.value

      tcp_options {
        min = 22
        max = 22
      }
    }
  }

  ingress_security_rules {
    protocol = "1"
    source   = "0.0.0.0/0"

    icmp_options {
      type = 3
      code = 4
    }
  }

  ingress_security_rules {
    protocol = "1"
    source   = var.vcn_cidr_block

    icmp_options {
      type = 3
    }
  }
}

# Public subnet (for head node)
resource "oci_core_subnet" "public" {
  count                      = var.use_existing_vcn ? 0 : 1
  compartment_id             = var.compartment_ocid
  display_name               = local.public_subnet_name
  vcn_id                     = oci_core_virtual_network.this[0].id
  cidr_block                 = local.public_subnet_cidr
  route_table_id             = oci_core_route_table.public[0].id
  security_list_ids          = [oci_core_security_list.public[0].id]
  prohibit_public_ip_on_vnic = false
  dns_label                  = "publicsub"
}

# Private subnet (for BM nodes / cluster network primary VNIC)
resource "oci_core_subnet" "private" {
  count                      = var.use_existing_vcn ? 0 : 1
  compartment_id             = var.compartment_ocid
  display_name               = local.private_subnet_name
  vcn_id                     = oci_core_virtual_network.this[0].id
  cidr_block                 = local.private_subnet_cidr
  route_table_id             = oci_core_route_table.private[0].id
  security_list_ids          = [oci_core_security_list.private[0].id]
  prohibit_public_ip_on_vnic = true
  dns_label                  = "privatesub"
}

# Locals to abstract between new vs existing networking
locals {
  vcn_id            = var.use_existing_vcn ? var.existing_vcn_id : oci_core_virtual_network.this[0].id
  public_subnet_id  = var.use_existing_vcn ? var.existing_public_subnet_id : oci_core_subnet.public[0].id
  private_subnet_id = var.use_existing_vcn ? var.existing_private_subnet_id : oci_core_subnet.private[0].id
  # AD-specific subnet launches must use the subnet's AD or instance pool creation can stay at 0/N.
  private_subnet_ad = var.use_existing_vcn ? try(trimspace(data.oci_core_subnet.existing_private[0].availability_domain), "") : try(trimspace(oci_core_subnet.private[0].availability_domain), "")
  public_subnet_ad  = var.use_existing_vcn ? try(trimspace(data.oci_core_subnet.existing_public[0].availability_domain), "") : try(trimspace(oci_core_subnet.public[0].availability_domain), "")
  stack_ad          = trimspace(var.availability_domain)
  # Single AD for head VM + compute cluster + BMs. Explicit var wins; else one shared fallback (private subnet, then public, then first tenancy AD).
  cluster_ad = length(local.stack_ad) > 0 ? local.stack_ad : (
    length(local.private_subnet_ad) > 0 ? local.private_subnet_ad : (
      length(local.public_subnet_ad) > 0 ? local.public_subnet_ad : local.ad_name
    )
  )
  head_node_ad       = local.cluster_ad
  cluster_network_ad = local.cluster_ad

  # BM instance create (compute cluster path); same knob as former cluster-network wait.
  bm_instance_create_timeout = trimspace(var.cluster_network_create_timeout) != "" ? var.cluster_network_create_timeout : "2h"

  # OCI rejects keys with stray CR (common when ssh_public_key is pasted from Windows); never emit empty lines.
  cluster_ssh_authorized_keys = join("\n", compact([
    trimspace(replace(var.ssh_public_key, "\r", "")),
    chomp(trimspace(replace(tls_private_key.cluster_ssh.public_key_openssh, "\r", ""))),
  ]))

  # Custom BM images: ensure stack SSH keys land on common users at first boot.
  bm_user_data_b64 = var.bm_imds_ssh_key_bootstrap ? base64encode(replace(replace(templatefile("${path.module}/scripts/bm_imds_ssh_bootstrap.sh", {
    stack_ssh_authorized_keys_b64 = base64encode(local.cluster_ssh_authorized_keys)
  }), "\r\n", "\n"), "\r", "\n")) : ""
}

# Single zip of playbooks (only when run_ansible_from_head = true). Written as its own cloud-init file; bootstrap script stays small so user_data + ssh_authorized_keys stays under OCI’s 32 KiB metadata limit.
# Exclude site.yml (oci-hpc mega-playbook) — unnecessary bulk.
data "archive_file" "playbooks" {
  count       = var.run_ansible_from_head ? 1 : 0
  type        = "zip"
  source_dir  = "${path.module}/playbooks"
  output_path = "${path.module}/.terraform/playbooks.zip"
  excludes    = ["site.yml", "inventory/hosts.sample"]
}

# Bootstrap script inputs (only used when run_ansible_from_head = true)
locals {
  # Omit stack_ssh_authorized_keys_lines: keys are already on instances via OCI metadata; including them here duplicated ~1–2KiB+ inside user_data (over limit).
  extra_vars_yaml = <<-EOT
rhsm_username: ${jsonencode(var.rhsm_username)}
rhsm_password: ${jsonencode(var.rhsm_password)}
rdma_ping_target: ${jsonencode(var.rdma_ping_target)}
cluster_ssh_user: ${jsonencode(var.instance_ssh_user)}
stack_ssh_authorized_keys_lines: []
EOT
  bm_private_ips_csv = var.run_ansible_from_head ? join(",", compact(oci_core_instance.bm_compute_nodes[*].private_ip)) : ""
  # Keep user_data under OCI 32KB: embed BM private IPs only (no OCID+VNIC jq loop in bootstrap).
  bootstrap_template_vars = var.run_ansible_from_head ? {
    compartment_id      = var.compartment_ocid
    region              = var.region
    tenancy_ocid        = var.tenancy_ocid
    instance_ssh_user   = var.instance_ssh_user
    head_node_ssh_user  = var.head_node_ssh_user != "" ? var.head_node_ssh_user : "opc"
    payload_b64         = filebase64(data.archive_file.playbooks[0].output_path)
    extra_vars_b64      = base64encode(local.extra_vars_yaml)
    rhsm_username_b64   = base64encode(var.rhsm_username)
    rhsm_password_b64   = base64encode(var.rhsm_password)
    bm_private_ips_csv  = local.bm_private_ips_csv
    ssh_private_key_b64 = base64encode(tls_private_key.cluster_ssh.private_key_openssh)
  } : {}
}

# -------------------------------------------------------------------
# Head node (VM.Standard.E6.Flex)
# -------------------------------------------------------------------

resource "oci_core_instance" "head_node" {
  compartment_id      = var.compartment_ocid
  availability_domain = local.head_node_ad
  # After BM nodes exist (Ansible bootstrap needs OCIDs / private IPs in user_data).
  depends_on = [time_sleep.wait_bm_instances]

  display_name = local.head_name
  shape        = "VM.Standard.E6.Flex"

  shape_config {
    ocpus         = 1
    memory_in_gbs = 8
  }

  agent_config {
    is_management_disabled = true
  }

  source_details {
    source_type = "image"
    # When head_node_image_ocid is empty, use latest OL8 so head doesn't need RHSM; Ansible registers RHEL on BM only.
    source_id = var.head_node_image_ocid != "" ? var.head_node_image_ocid : (length(data.oci_core_images.ol8_head.images) > 0 ? data.oci_core_images.ol8_head.images[0].id : var.bm_node_image_ocid)
  }

  create_vnic_details {
    subnet_id        = local.public_subnet_id
    assign_public_ip = true
    hostname_label   = "headnode"
  }

  # Always set user_data so sshd accepts ssh-rsa keys from metadata (OpenSSH 9+); optionally embed Ansible bootstrap.
  metadata = merge(
    { ssh_authorized_keys = local.cluster_ssh_authorized_keys },
    {
      user_data = base64encode(replace(replace(templatefile("${path.module}/scripts/cloud_init_head.yaml.tpl", {
        run_bootstrap          = var.run_ansible_from_head
        bootstrap_script_b64   = var.run_ansible_from_head ? base64encode(replace(replace(templatefile("${path.module}/scripts/head_bootstrap.sh.tpl", local.bootstrap_template_vars), "\r\n", "\n"), "\r", "\n")) : ""
        authorized_keys_b64    = base64encode(local.cluster_ssh_authorized_keys)
        head_ssh_user          = trimspace(var.head_node_ssh_user) != "" ? trimspace(var.head_node_ssh_user) : "opc"
        playbooks_zip_b64      = var.run_ansible_from_head ? filebase64(data.archive_file.playbooks[0].output_path) : ""
        head_home_readme_b64   = base64encode(replace(replace(local.head_home_readme_markdown, "\r\n", "\n"), "\r", "\n"))
      }), "\r\n", "\n"), "\r", "\n"))
    }
  )
}

# -------------------------------------------------------------------
# BM nodes via compute cluster (oracle-quickstart/oci-hpc compute-cluster.tf + compute-nodes.tf)
# Avoids cluster network + instance pool "Create instances in pool" path.
# -------------------------------------------------------------------

resource "oci_core_compute_cluster" "bm_compute" {
  lifecycle {
    precondition {
      condition = !var.use_existing_vcn || (
        length(trimspace(var.existing_vcn_id)) > 0 &&
        length(trimspace(var.existing_public_subnet_id)) > 0 &&
        length(trimspace(var.existing_private_subnet_id)) > 0
      )
      error_message = "When use_existing_vcn is true, set existing_vcn_id, existing_public_subnet_id, and existing_private_subnet_id (non-empty)."
    }
  }

  availability_domain = local.cluster_network_ad
  compartment_id      = var.compartment_ocid
  display_name        = local.compute_cluster_name
}

resource "oci_core_instance" "bm_compute_nodes" {
  count      = var.bm_node_count
  depends_on = [oci_core_compute_cluster.bm_compute]

  availability_domain = local.cluster_network_ad
  compartment_id      = var.compartment_ocid
  display_name        = "${local.bm_name_prefix}-${count.index + 1}"
  shape               = var.bm_node_shape

  capacity_reservation_id = trimspace(var.bm_capacity_reservation_id) != "" ? var.bm_capacity_reservation_id : null

  dynamic "platform_config" {
    for_each = var.bm_generic_platform_config ? [1] : []
    content {
      type                                           = "GENERIC_BM"
      is_symmetric_multi_threading_enabled           = var.bm_smt_enabled
      is_access_control_service_enabled              = false
      is_input_output_memory_management_unit_enabled = false
      are_virtual_instructions_enabled               = false
      numa_nodes_per_socket                          = var.bm_numa_nodes_per_socket
      percentage_of_cores_enabled                    = 100
    }
  }

  agent_config {
    are_all_plugins_disabled = false
    is_management_disabled   = true
    is_monitoring_disabled   = false
    plugins_config {
      name          = "OS Management Service Agent"
      desired_state = "DISABLED"
    }
    dynamic "plugins_config" {
      for_each = var.use_compute_agent ? ["ENABLED"] : ["DISABLED"]
      content {
        name          = "Compute HPC RDMA Authentication"
        desired_state = plugins_config.value
      }
    }
    dynamic "plugins_config" {
      for_each = var.use_compute_agent ? ["ENABLED"] : ["DISABLED"]
      content {
        name          = "Compute HPC RDMA Auto-Configuration"
        desired_state = plugins_config.value
      }
    }
  }

  metadata = merge(
    { ssh_authorized_keys = local.cluster_ssh_authorized_keys },
    local.bm_user_data_b64 != "" ? { user_data = local.bm_user_data_b64 } : {}
  )

  source_details {
    source_type             = "image"
    source_id               = var.bm_node_image_ocid
    boot_volume_size_in_gbs = var.bm_boot_volume_size_gbs
    boot_volume_vpus_per_gb = 30
  }

  compute_cluster_id = oci_core_compute_cluster.bm_compute.id

  create_vnic_details {
    subnet_id        = local.private_subnet_id
    assign_public_ip = false
  }

  timeouts {
    create = local.bm_instance_create_timeout
    update = "30m"
    delete = "30m"
  }
}

# Serial console / VNC (SSH tunnel) — optional troubleshooting access per BM instance.
resource "oci_core_instance_console_connection" "bm_vnc" {
  count = var.create_vnc ? var.bm_node_count : 0

  # Defined instance order must match bm_compute_nodes index (replace BM instances to re-bind).
  instance_id = oci_core_instance.bm_compute_nodes[count.index].id
  public_key  = trimspace(var.ssh_public_key)
}

resource "time_sleep" "wait_bm_instances" {
  create_duration = var.run_ansible_from_head ? var.bm_pool_ready_wait : "0s"
  depends_on      = [oci_core_instance.bm_compute_nodes]
}
