# Frequently asked questions

## What if I get bare metal capacity errors (“out of host capacity”)?

Bare metal capacity is **regional and per availability domain (AD)**. Try:

- **Another AD** — set **cluster network / BM availability domain** (or equivalent) to a different AD in the same region if your shape is offered there.
- **Another region** — if your workload allows it, deploy where **BM.Optimized3** (or your chosen shape) has capacity.
- **Retry later** — capacity frees up as other customers release hosts.
- **Fewer nodes** — temporarily reduce the BM count to get a successful create, then scale later if your process allows.
- **Policies** — capacity errors are **not** an IAM symptom, but if **create** fails with **authorization** or **not authorized**, review [Prerequisites (policies and permissions)](README.md#prerequisites-policies-and-permissions) in the main README.

## Do I need a capacity reservation?

**Usually no** for a **small** cluster (on the order of **~4** bare metal hosts). Reservations help when you need **guaranteed** capacity at scale or for predictable large launches. If you routinely see capacity errors at your target size, discuss **capacity reservations** with your Oracle account team.

## How can I check if RDMA is authenticated?

On the **head node**, open the **README in the default SSH user’s home directory** (for Oracle Linux the user is often `opc`):

```bash
cat ~/README.md
```

That file summarizes how to verify **RDMA re-auth** on the bare metal nodes (timer, script, rerun playbook). The same checks are also in **[README.md, Step 5](README.md#step-5-log-in-and-verify)**.

## The custom RHEL image fails to launch (404 / not found)

Custom images are **regional**. Use an image that was **imported in the same region** where you deploy the stack. An image OCID from another region will not work.

## Ansible folder or bootstrap log is missing on the head (`/opt/oci-hpc-ansible`)

The head only runs Ansible **cloud-init** on **first boot**. If **Run Ansible from head** was **off** when the head was created, or the head is from an older configuration, turn the variable **on** and **replace the head instance** so cloud-init runs again. See **[STACK-REFERENCE.md](STACK-REFERENCE.md)** troubleshooting.

## I cannot SSH from the head to the bare metal nodes

- Confirm you are using the **correct user** on the BMs (often **`cloud-user`** for RHEL; set **`instance_ssh_user`** to match your image).
- Use **`docs/HEAD-BM-SSH-README.md`** for a supported **passwordless SSH** setup from the head.
- **OpenSSH** may reject **`ssh-rsa`** keys; this stack configures the head to accept common OCI-injected keys—**replace the head** after upgrading the stack if you still see refusals.

## Plan/apply times out while creating bare metal

Bare metal can take **45–90+ minutes** per node in busy regions. Increase **BM / cluster network create timeout** and **BM pool ready wait** in the stack variables. See **[STACK-REFERENCE.md](STACK-REFERENCE.md#terraform-errors)**.

## Where is the full variable list and troubleshooting?

See **[STACK-REFERENCE.md](STACK-REFERENCE.md)** and **[OCI-RESOURCE-MANAGER-GUIDE.md](OCI-RESOURCE-MANAGER-GUIDE.md)**.

## Resource Manager still shows old variables (cluster prefix, BM timeouts, HPC agent text, etc.)

The console wizard uses the **`schema.yaml` inside the zip that was used when the stack was created** (or last uploaded). It does **not** auto-sync when the GitHub repo changes. **Create a new stack** from a fresh zip, or **edit the stack** and **replace the Terraform configuration** with an archive built from the current repository. The README **Deploy** button downloads **`master`** (latest commit). If you pin a stack to some other ref (for example a **Git tag**), that ref must include the `schema.yaml` you expect. See **[OCI-RESOURCE-MANAGER-GUIDE.md](OCI-RESOURCE-MANAGER-GUIDE.md)** (section *When the console UI does not match the latest `schema.yaml`*).
