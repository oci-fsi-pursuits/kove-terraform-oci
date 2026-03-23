# RHEL 8.8 image for OCI — quick steps

Use this flow to get a **RHEL 8.8** image into Oracle Cloud Infrastructure so you can use its **OCID** in this stack (`bm_node_image_ocid`).

---

## 1. Create a Red Hat account

1. Open one of these (same end goal — a Red Hat login):
   - **[access.redhat.com/registration](https://access.redhat.com/registration)** — main portal registration  
   - **[redhat.com register](https://www.redhat.com/wapps/ugc/register.html)** — alternate entry (you may be redirected through a short flow)
2. Complete the form (email, password, name/company as prompted).
3. **Recommended:** Sign up for **[Red Hat Developer](https://developers.redhat.com/)** (free) so you can download RHEL for development without a paid subscription.

> **Tip:** URLs with `_flowExecutionKey=…` in the query string are often one-time; if a bookmarked link breaks, start from **access.redhat.com/registration** instead.

---

## 2. Download RHEL 8.8 (KVM / cloud image)

1. Sign in at **[Red Hat Customer Portal — Downloads](https://access.redhat.com/downloads)** (or **developers.redhat.com** → Downloads, depending on your subscription).
2. Find **Red Hat Enterprise Linux 8**.
3. Choose a **8.8** build and a format OCI can import — typically:
   - **KVM Guest Image** (`.qcow2`), or  
   - **Red Hat Universal Base Image** / **Generic Cloud** if 8.8 is offered in that line.
4. Download the file (large; use a stable network).

> **Tip:** If you only see **8.10** (or another minor), check whether your workload allows that minor, or use a **8.8**-specific image if still available in the portal. This stack was written expecting **RHEL 8.8** for BM nodes.

---

## 3. Upload the image to OCI Object Storage

1. In the **OCI Console**, open your **compartment** (same one you use for the stack).
2. **Storage → Buckets → Create bucket** (e.g. `rhel-images`, no public access needed).
3. **Upload** the `.qcow2` (or chosen) file.  
   - Use **multipart upload** for large objects if the console suggests it.

---

## 4. Import as a custom image in OCI

1. **Compute → Images → Import image**.
2. Set **Import from Object Storage** and pick your **bucket** and **object** (the uploaded file).
3. Choose an **operating system** compatible with **Linux / RHEL** (per the import wizard).
4. Set **Image type** / **launch mode** per Oracle’s options for your file format (often **QCOW2** / **Paravirtualized** or as documented for custom images in your region).
5. Start the import and wait until status is **Available**.

> **Verify:** See Oracle’s current doc: **[Importing a custom image](https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/importingcustomimage.htm)** — formats and launch options change over time.

---

## 5. Use the image in this Terraform stack

1. Open the **image details** in **Compute → Images**.
2. Copy the **OCID** of the imported image.
3. In **Resource Manager** (or `terraform.tfvars`), set **`bm_node_image_ocid`** to that OCID.
4. For the head node, leave **`head_node_image_ocid`** empty to use **Oracle Linux 8** from OCI, or set it to another image OCID if you want RHEL on the head too.

---

## Checklist

| Step | Done |
|------|------|
| Red Hat account (and Developer, if using) | ☐ |
| RHEL 8.x image downloaded (8.8 preferred) | ☐ |
| Object Storage bucket + upload | ☐ |
| Custom image imported and **Available** | ☐ |
| OCID pasted into stack variable **`bm_node_image_ocid`** | ☐ |

---

## Related

- Stack **README** — variables, Ansible, RHSM.
- **RHSM** username/password in the stack are still used by the playbook to register nodes (separate from *importing* the image).
