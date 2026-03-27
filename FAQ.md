# Frequently asked questions

## What if I get bare metal capacity errors (“out of host capacity”)?

Bare metal capacity is **regional and per availability domain (AD)**. Try:

- **Another AD** — set **availability domain** to a different AD in the same region if your shape is offered there (or leave it unset and rely on subnet placement).
- **Another region** — if your workload allows it, deploy where **BM.Optimized3** (or your chosen shape) has capacity.
- **Retry later** — capacity frees up as other customers release hosts.
- **Fewer nodes** — temporarily reduce the BM count to get a successful create, then scale later if your process allows.
- **Policies** — capacity errors are **not** an IAM symptom, but if **create** fails with **authorization** or **not authorized**, review [Prerequisites (policies and permissions)](README.md#prerequisites-policies-and-permissions) in the main README.

## Do I need a capacity reservation?

**Usually no** for a **small** cluster (on the order of **~4** bare metal hosts). Reservations help when you need **guaranteed** capacity at scale or for predictable large launches. If you routinely see capacity errors at your target size, discuss **capacity reservations** with your Oracle account team.

## How can I check if RDMA is authenticated?

On the **head**, **`cat ~/README.md`** has a short reminder. Full **RDMA re-auth** checks on a **BM node** (SSH from the head) are in **[README.md, Step 5](README.md#step-5-log-in-and-verify)** (systemd timer, script path, rerun playbook from `/opt/oci-hpc-ansible` if needed).

## The custom RHEL image fails to launch (404 / not found)

Custom images are **regional**. Use an image that was **imported in the same region** where you deploy the stack. An image OCID from another region will not work.

## Ansible folder or bootstrap log is missing on the head (`/opt/oci-hpc-ansible`)

The head only runs Ansible **cloud-init** on **first boot**. If **Run Ansible from head** was **off** when the head was created, or the head is from an older configuration, turn the variable **on** and **replace the head instance** so cloud-init runs again. See **[STACK-REFERENCE.md](STACK-REFERENCE.md)** troubleshooting.

## I cannot SSH from the head to the bare metal nodes

- Confirm you are using the **correct user** on the BMs (often **`cloud-user`** for RHEL; set **`instance_ssh_user`** to match your image).
- Use **`docs/HEAD-BM-SSH-README.md`** for a supported **passwordless SSH** setup from the head.
- **OpenSSH** may reject **`ssh-rsa`** keys; this stack configures the head to accept common OCI-injected keys—**replace the head** after upgrading the stack if you still see refusals.

## I cannot SSH from a bastion to the bare metal nodes

If the bastion is **in the same VCN** as the stack (e.g. head on the public subnet, BMs on the private subnet), Terraform-created security lists allow **all protocols** from the **VCN CIDR** to the private subnet. If the bastion lives in **another VCN**, **on-premises**, or a **peered** network, set **`private_subnet_ssh_sources_extras`** to that CIDR (comma-separated if needed) when Terraform **creates** the VCN. If you use **Use existing VCN**, add an equivalent **ingress TCP 22** (or broader intra-network) rule on the **private subnet’s security list** yourself. See **[STACK-REFERENCE.md](STACK-REFERENCE.md)** (Network Configuration).

## Plan/apply times out while creating bare metal

Bare metal can take **45–90+ minutes** per node in busy regions. Increase **BM / cluster network create timeout** and **BM pool ready wait** in the stack variables. See **[STACK-REFERENCE.md](STACK-REFERENCE.md#terraform-errors)**.

## Where is the full variable list and troubleshooting?

See **[STACK-REFERENCE.md](STACK-REFERENCE.md)** and **[OCI-RESOURCE-MANAGER-GUIDE.md](OCI-RESOURCE-MANAGER-GUIDE.md)**.
