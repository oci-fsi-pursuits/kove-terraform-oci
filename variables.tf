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

variable "ssh_private_key" {
  type        = string
  description = "Optional: SSH private key matching ssh_public_key. When set and Run Ansible from head is true, this key is placed on the head node so it can SSH to BM nodes (BM nodes already have the public key). Leave empty to run the playbook from your machine instead."
  default     = ""
  sensitive   = true
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

variable "cluster_network_create_timeout" {
  type        = string
  description = "Max time to wait for the BM cluster network to reach RUNNING (e.g. 90m, 2h). Bare metal capacity can take 45–90+ minutes."
  default     = "90m"
}

variable "bm_pool_ready_wait" {
  type        = string
  description = "Delay after cluster network is RUNNING before Terraform reads BM instance IDs from the instance pool (e.g. 10m, 15m). Increase if apply errors on BM data sources or bootstrap has empty [bm]."
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

variable "existing_rdma_subnet_id" {
  type        = string
  description = "Optional: subnet OCID for BM secondary (RDMA) VNIC on the cluster network. When use_existing_vcn is true and this is empty, the private subnet is used for both primary and secondary (Oracle doc pattern). Prefer a dedicated subnet in the VCN for RDMA when possible."
  default     = ""
}

variable "cluster_network_availability_domain" {
  type        = string
  description = "Optional: availability domain for BM cluster network (e.g. Uocm:PHX-AD-1). Must support BM.Optimized3.36. If empty, uses the tenancy's first AD — wrong AD often yields immediate TERMINATED."
  default     = ""
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
  description = "If true, head node user_data runs Ansible at first boot (instance principal required; see README)."
  default     = false
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
