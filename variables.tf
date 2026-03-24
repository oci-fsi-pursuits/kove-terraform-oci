variable "tenancy_ocid" {
  type        = string
  description = "OCI Tenancy OCID"
}

variable "region" {
  type        = string
  description = "OCI region (e.g. us-ashburn-1)"
}

variable "compartment_ocid" {
  type        = string
  description = "Compartment to host the cluster"
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key to inject into instances"
}

variable "bm_node_image_ocid" {
  type        = string
  description = "RHEL 8.8 image OCID for BM.Optimized3.36 nodes (cluster network)"
}

variable "head_node_image_ocid" {
  type        = string
  description = "Image OCID for the head node. If empty, uses latest Oracle Linux 8 (so head needs no RHSM); Ansible registers RHEL on BM only. Set to override (e.g. specific OL version)."
  default     = ""
}

variable "bm_node_count" {
  type        = number
  description = "Number of BM nodes in the cluster network (RDMA)"
  default     = 4
}

variable "cluster_display_name_prefix" {
  type        = string
  description = "Prefix for cluster network, pool, instance configuration, and head display names (change for a visibly distinct deployment)."
  default     = "bm"
}

variable "bm_node_shape" {
  type        = string
  description = "Bare metal shape for cluster network nodes (must match capacity / image)."
  default     = "BM.Optimized3.36"
}

variable "bm_capacity_reservation_id" {
  type        = string
  description = "Optional: BM compute capacity reservation OCID. Required in some tenancies for BM.Optimized3; leave empty if not using reservations."
  default     = ""
}

variable "bm_generic_platform_config" {
  type        = bool
  description = "Set true to add oci-hpc-style GENERIC_BM platform_config. BM.Optimized3.36 on compute-cluster instances often rejects this (400); leave false unless OCI/documents require it for your shape."
  default     = false
}

variable "bm_smt_enabled" {
  type        = bool
  description = "Symmetric multithreading for BM platform_config (oci-hpc default true)."
  default     = true
}

variable "bm_numa_nodes_per_socket" {
  type        = string
  description = "NUMA nodes per socket for GENERIC_BM (oci-hpc uses NPS1 for GENERIC_BM)."
  default     = "NPS1"
}

variable "cluster_network_create_timeout" {
  type        = string
  description = "Max wait for each BM instance create (compute cluster path). If empty, defaults to 2h. (Variable name kept for backward compatibility with existing tfvars.)"
  default     = ""
}

variable "bm_pool_ready_wait" {
  type        = string
  description = "Extra delay after BM instances exist before creating the head node (lets VNICs stabilize before Terraform embeds private IPs in bootstrap user_data)."
  default     = "10m"
}

# -------------------------------------------------------------------
# Networking control
# -------------------------------------------------------------------

variable "use_existing_vcn" {
  type        = bool
  description = "If true, use existing VCN and subnets; if false, create new networking."
  default     = false
}

variable "existing_vcn_id" {
  type        = string
  description = "Existing VCN OCID (required if use_existing_vcn = true)"
  default     = ""
}

variable "existing_public_subnet_id" {
  type        = string
  description = "Existing public subnet OCID for head node"
  default     = ""
}

variable "existing_private_subnet_id" {
  type        = string
  description = "Existing private subnet OCID for BM nodes"
  default     = ""
}

variable "cluster_network_availability_domain" {
  type        = string
  description = "Optional: same role as oci-hpc `ad` for cluster network + instance configuration. If empty, uses the private subnet's AD when the subnet is AD-specific, otherwise first tenancy AD."
  default     = ""
}

variable "use_compute_agent" {
  type        = bool
  description = "oracle-quickstart/oci-hpc `use_compute_agent`: enable Oracle Cloud Agent HPC RDMA plugins on BM nodes. Set false for custom RHEL images that do not support these plugins (configure RDMA via Ansible instead)."
  default     = true
}

variable "bm_boot_volume_size_gbs" {
  type        = number
  description = "Boot volume size in GB for BM instance configuration (custom images may need 120+)."
  default     = 120

  validation {
    condition     = var.bm_boot_volume_size_gbs >= 50 && var.bm_boot_volume_size_gbs <= 32768
    error_message = "bm_boot_volume_size_gbs must be between 50 and 32768."
  }
}

# -------------------------------------------------------------------
# Ansible from head node (Resource Manager)
# -------------------------------------------------------------------

variable "run_ansible_from_head" {
  type        = bool
  description = "If true, Terraform embeds ./playbooks as a zip in head user_data; cloud-init runs scripts/head_bootstrap.sh.tpl which unpacks to /opt/oci-hpc-ansible and runs configure-rhel-rdma.yml. OCI runs user_data only on first boot—replace the head instance after changing this. Requires dynamic group + instance principal policies for OCI CLI from the head. Default true so Resource Manager and fresh clones get automation unless explicitly disabled."
  default     = true
}

variable "rhsm_username" {
  type        = string
  description = "RHSM username for RHEL registration (used when run_ansible_from_head = true)."
  default     = ""
  sensitive   = true
}

variable "rhsm_password" {
  type        = string
  description = "RHSM password for RHEL registration (used when run_ansible_from_head = true)."
  default     = ""
  sensitive   = true
}

variable "rdma_ping_target" {
  type        = string
  description = "RDMA interface ping target IP (e.g. another BM node's secondary VNIC IP) for playbook when run_ansible_from_head = true."
  default     = ""
}

variable "instance_ssh_user" {
  type        = string
  description = "SSH user for BM nodes (e.g. cloud-user for RHEL). Used for head too unless head_node_ssh_user is set."
  default     = "cloud-user"
}

variable "head_node_ssh_user" {
  type        = string
  description = "SSH user for the head node only. Default 'opc' matches Oracle Linux (default head image). Set to cloud-user if head is RHEL."
  default     = "opc"
}
