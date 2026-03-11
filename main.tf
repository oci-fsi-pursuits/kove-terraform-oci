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

# -------------------------------------------------------------------
# Networking (optional create vs existing)
# -------------------------------------------------------------------

# Create VCN only when use_existing_vcn = false
resource "oci_core_virtual_network" "this" {
  count          = var.use_existing_vcn ? 0 : 1
  cidr_block     = "10.0.0.0/16"
  compartment_id = var.compartment_ocid
  display_name   = "cluster-vcn"
  dns_label      = "clustervcn"
}

resource "oci_core_internet_gateway" "this" {
  count          = var.use_existing_vcn ? 0 : 1
  compartment_id = var.compartment_ocid
  display_name   = "cluster-igw"
  enabled        = true
  vcn_id         = oci_core_virtual_network.this[0].id
}

resource "oci_core_nat_gateway" "this" {
  count          = var.use_existing_vcn ? 0 : 1
  compartment_id = var.compartment_ocid
  display_name   = "cluster-nat"
  vcn_id         = oci_core_virtual_network.this[0].id
}

resource "oci_core_route_table" "public" {
  count          = var.use_existing_vcn ? 0 : 1
  compartment_id = var.compartment_ocid
  display_name   = "cluster-public-rt"
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
  display_name   = "cluster-private-rt"
  vcn_id         = oci_core_virtual_network.this[0].id

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.this[0].id
  }
}

# Security list for public subnet: SSH from internet (adjust as needed)
resource "oci_core_security_list" "public" {
  count          = var.use_existing_vcn ? 0 : 1
  compartment_id = var.compartment_ocid
  display_name   = "cluster-public-sl"
  vcn_id         = oci_core_virtual_network.this[0].id

  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }

  ingress_security_rules {
    protocol = "6" # TCP
    source   = "0.0.0.0/0"

    tcp_options {
      min = 22
      max = 22
    }
  }

  # Allow ICMP (ping) from anywhere (optional)
  ingress_security_rules {
    protocol = "1"
    source   = "0.0.0.0/0"

    icmp_options {
      type = 8
      code = 0
    }
  }
}

# Security list for private subnet: only intra-VCN (and you can add more)
resource "oci_core_security_list" "private" {
  count          = var.use_existing_vcn ? 0 : 1
  compartment_id = var.compartment_ocid
  display_name   = "cluster-private-sl"
  vcn_id         = oci_core_virtual_network.this[0].id

  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }

  ingress_security_rules {
    protocol = "all"
    source   = "10.0.0.0/16"
  }
}

# Public subnet (for head node)
resource "oci_core_subnet" "public" {
  count                      = var.use_existing_vcn ? 0 : 1
  compartment_id             = var.compartment_ocid
  display_name               = "cluster-public-subnet"
  vcn_id                     = oci_core_virtual_network.this[0].id
  cidr_block                 = "10.0.1.0/24"
  route_table_id             = oci_core_route_table.public[0].id
  security_list_ids          = [oci_core_security_list.public[0].id]
  prohibit_public_ip_on_vnic = false
  dns_label                  = "publicsub"
}

# Private subnet (for BM nodes / cluster network primary VNIC)
resource "oci_core_subnet" "private" {
  count                      = var.use_existing_vcn ? 0 : 1
  compartment_id             = var.compartment_ocid
  display_name               = "cluster-private-subnet"
  vcn_id                     = oci_core_virtual_network.this[0].id
  cidr_block                 = "10.0.2.0/24"
  route_table_id             = oci_core_route_table.private[0].id
  security_list_ids          = [oci_core_security_list.private[0].id]
  prohibit_public_ip_on_vnic = true
  dns_label                  = "privatesub"
}

# Cluster network subnet (RDMA secondary VNIC; only when creating new VCN)
resource "oci_core_subnet" "cluster" {
  count                      = var.use_existing_vcn ? 0 : 1
  compartment_id             = var.compartment_ocid
  display_name               = "cluster-rdma-subnet"
  vcn_id                     = oci_core_virtual_network.this[0].id
  cidr_block                 = "10.0.3.0/24"
  route_table_id             = oci_core_route_table.private[0].id
  security_list_ids          = [oci_core_security_list.private[0].id]
  prohibit_public_ip_on_vnic = true
  dns_label                  = "clustersub"
}

# Locals to abstract between new vs existing networking
locals {
  vcn_id             = var.use_existing_vcn ? var.existing_vcn_id : oci_core_virtual_network.this[0].id
  public_subnet_id   = var.use_existing_vcn ? var.existing_public_subnet_id : oci_core_subnet.public[0].id
  private_subnet_id  = var.use_existing_vcn ? var.existing_private_subnet_id : oci_core_subnet.private[0].id
  cluster_subnet_id  = var.use_existing_vcn ? var.existing_private_subnet_id : oci_core_subnet.cluster[0].id
}

# Single zip of playbooks to stay under OCI metadata limit (32KB). Only used when run_ansible_from_head = true.
data "archive_file" "playbooks" {
  count       = var.run_ansible_from_head ? 1 : 0
  type        = "zip"
  source_dir  = "${path.module}/playbooks"
  output_path = "${path.module}/.terraform/playbooks.zip"
}

# Bootstrap script inputs (only used when run_ansible_from_head = true)
locals {
  instance_pool_id  = one(oci_core_cluster_network.bm_cluster.instance_pools).id
  extra_vars_yaml   = <<-EOT
rhsm_username: ${jsonencode(var.rhsm_username)}
rhsm_password: ${jsonencode(var.rhsm_password)}
rdma_ping_target: ${jsonencode(var.rdma_ping_target)}
cluster_ssh_user: ${jsonencode(var.instance_ssh_user)}
EOT
  # BM private IPs from Terraform (comma-separated); skip null/empty so script can fall back to OCI CLI if needed.
  bm_private_ips_csv = var.run_ansible_from_head ? join(",", [for i in range(var.bm_node_count) : try(data.oci_core_instance.bm_instances[i].private_ip, "") if try(data.oci_core_instance.bm_instances[i].private_ip, "") != ""]) : ""
  # One compressed payload + small extra_vars to keep user_data under 32KB. RHSM b64 so script can register before dnf.
  bootstrap_template_vars = var.run_ansible_from_head ? {
    instance_pool_id    = local.instance_pool_id
    compartment_id      = var.compartment_ocid
    region              = var.region
    tenancy_ocid        = var.tenancy_ocid
    bm_count            = var.bm_node_count
    instance_ssh_user   = var.instance_ssh_user
    head_node_ssh_user  = var.head_node_ssh_user != "" ? var.head_node_ssh_user : "opc"
    payload_b64         = filebase64(data.archive_file.playbooks[0].output_path)
    extra_vars_b64      = base64encode(local.extra_vars_yaml)
    rhsm_username_b64   = base64encode(var.rhsm_username)
    rhsm_password_b64   = base64encode(var.rhsm_password)
    bm_private_ips_csv  = local.bm_private_ips_csv
    ssh_private_key_b64 = var.ssh_private_key != "" ? base64encode(var.ssh_private_key) : ""
  } : {}
}

# -------------------------------------------------------------------
# Head node (VM.Standard.E6.Flex)
# -------------------------------------------------------------------

resource "oci_core_instance" "head_node" {
  compartment_id      = var.compartment_ocid
  availability_domain = local.ad_name
  depends_on          = [time_sleep.wait_bm_instances]

  display_name = "head-node"
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
    source_id   = var.head_node_image_ocid != "" ? var.head_node_image_ocid : (length(data.oci_core_images.ol8_head.images) > 0 ? data.oci_core_images.ol8_head.images[0].id : var.bm_node_image_ocid)
  }

  create_vnic_details {
    subnet_id        = local.public_subnet_id
    assign_public_ip = true
    hostname_label   = "headnode"
  }

  # Match oci-hpc: user key first, then generated key; newline between and at end (OCI authorized_keys format)
  metadata = merge(
    { ssh_authorized_keys = "${trimspace(var.ssh_public_key)}\n${tls_private_key.cluster_ssh.public_key_openssh}\n" },
    var.run_ansible_from_head ? { user_data = base64encode(templatefile("${path.module}/scripts/cloud_init_bootstrap.yaml.tpl", { bootstrap_script_b64 = base64encode(templatefile("${path.module}/scripts/head_bootstrap.sh.tpl", local.bootstrap_template_vars)) })) } : {}
  )
}

# -------------------------------------------------------------------
# Cluster network (RDMA) for 4x BM.Optimized3.36
# -------------------------------------------------------------------

# Instance configuration template for cluster network (no create_vnic_details; cluster network provides VNICs)
resource "oci_core_instance_configuration" "bm_cluster" {
  compartment_id = var.compartment_ocid
  display_name   = "bm-cluster-config"

  instance_details {
    instance_type = "compute"
    launch_details {
      compartment_id      = var.compartment_ocid
      availability_domain = local.ad_name
      display_name        = "bm-node"
      shape               = "BM.Optimized3.36"

      source_details {
        source_type = "image"
        image_id    = var.bm_node_image_ocid
      }

      metadata = {
        ssh_authorized_keys = "${trimspace(var.ssh_public_key)}\n${tls_private_key.cluster_ssh.public_key_openssh}\n"
      }

      agent_config {
        are_all_plugins_disabled = false
        is_management_disabled   = true
        is_monitoring_disabled   = false
        plugins_config {
          name          = "Compute HPC RDMA Authentication"
          desired_state = "ENABLED"
        }
        plugins_config {
          name          = "Compute HPC RDMA Auto-Configuration"
          desired_state = "ENABLED"
        }
      }
    }
  }
}

resource "oci_core_cluster_network" "bm_cluster" {
  compartment_id = var.compartment_ocid
  display_name   = "bm-rdma-cluster"

  instance_pools {
    instance_configuration_id = oci_core_instance_configuration.bm_cluster.id
    size                      = var.bm_node_count
    display_name              = "bm-pool"
  }

  placement_configuration {
    availability_domain = local.ad_name
    primary_vnic_subnets {
      subnet_id = local.private_subnet_id
    }
    # OCI API expects 0 secondary_vnic_subnets; RDMA/secondary VNIC is managed by the platform for cluster networks.
  }
}

# -------------------------------------------------------------------
# BM instance private IPs via Terraform (like oci-hpc) when run_ansible_from_head
# -------------------------------------------------------------------
# Wait for instance pool to have instances, then read IPs via data sources so we
# inject them into the bootstrap script (no OCI CLI list-vnics on the head).
resource "time_sleep" "wait_bm_instances" {
  create_duration = var.run_ansible_from_head ? "5m" : "0s"
  depends_on      = [oci_core_cluster_network.bm_cluster]
}

data "oci_core_cluster_network_instances" "bm" {
  count = var.run_ansible_from_head ? 1 : 0

  cluster_network_id = oci_core_cluster_network.bm_cluster.id
  compartment_id     = var.compartment_ocid
  depends_on         = [time_sleep.wait_bm_instances]
}

data "oci_core_instance" "bm_instances" {
  count = var.run_ansible_from_head ? var.bm_node_count : 0

  instance_id = data.oci_core_cluster_network_instances.bm[0].instances[count.index]["id"]
}
