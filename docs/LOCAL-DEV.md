# Local Terraform development (optional)

**Customer-facing path stays the same:** use the **Deploy to Oracle Cloud** button in the [README](../README.md) so OCI Resource Manager pulls the zip from GitHub and uses `schema.yaml` for variables. No change to that flow is required.

This guide is for **engineers** who want faster iteration: same Terraform code, **local** `plan` / `apply` with values saved in a file instead of retyping them in the Console.

---

## 1. One-time setup

1. **OCI CLI API key** (local only; Resource Manager still uses the resource principal).
   - Install [OCI CLI](https://docs.oracle.com/en-us/iaas/Content/API/Concepts/cliconcepts.htm).
   - Run `oci setup config` and create `~/.oci/config` with a user API key and fingerprint.
   - The Terraform OCI provider will use this profile when **not** running inside Resource Manager.

2. **IAM** — the user or group for that API key needs the same style of policies you use for Resource Manager (manage compute, VCN, etc. in the target compartment).

3. **Terraform** — install [Terraform](https://developer.hashicorp.com/terraform/install) `>= 1.3.0`.

---

## 2. Save your variables once (`terraform.tfvars`)

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your OCIDs, keys, and flags
```

- **`terraform.tfvars` is gitignored** — do not commit it (especially `ssh_private_key`, `rhsm_password`).
- Terraform **automatically loads** `terraform.tfvars` in the module directory (no `-var-file` needed).
- Optional: split secrets into `secrets.auto.tfvars` and add that filename to `.gitignore` if you prefer.

Variable names match `variables.tf` / the Resource Manager UI (from `schema.yaml`).

---

## 3. Run Terraform locally

```bash
cd /path/to/kove-oci-build-2   # repo root with main.tf
terraform init
terraform plan
terraform apply
```

- **State file** is local (`terraform.tfstate`) unless you configure a [remote backend](https://developer.hashicorp.com/terraform/language/settings/backends/configuration). Resource Manager keeps **its own** state per stack — do not expect them to share state.
- For experiments, use a **dedicated compartment** or **unique display names** so local applies do not fight with a customer stack.

---

## 4. Parity with Resource Manager

- Same files the button uses: `main.tf`, `variables.tf`, `outputs.tf`, `schema.yaml`, `scripts/`, `playbooks/`, etc.
- To mimic RM’s zip exactly:

  ```powershell
  # Windows PowerShell (adjust paths)
  Compress-Archive -Path main.tf,variables.tf,outputs.tf,schema.yaml,scripts,inventory.tpl,playbooks -DestinationPath stack-test.zip -Force
  ```

  Upload `stack-test.zip` to a **test** stack when you want Console-only validation.

---

## 5. Orchestrating from GitHub without replacing the button

The **button** remains the main distribution: it points at `…/archive/refs/heads/master.zip` and needs no secrets in GitHub.

Optional **automation** (CI/CD or internal pipeline) can run the same Terraform using:

- **GitHub Actions** (or other CI) with secrets: `TF_VAR_tenancy_ocid`, `TF_VAR_compartment_ocid`, … or a base64-encoded tfvars blob.
- **OCI CLI** authenticated with a [GitHub OIDC → OCI dynamic group](https://docs.oracle.com/en-us/iaas/Content/Identity/Tasks/federatinggithub.htm) pattern (advanced), or a stored API key secret.

That is **in addition to** the button, not instead of it, unless you explicitly move customers to a different onboarding path.

---

## Summary

| Method | Auth | Variables | Best for |
|--------|------|-----------|----------|
| **Deploy button → Resource Manager** | Resource principal | Console / `schema.yaml` | Customers, audits |
| **Local Terraform + `terraform.tfvars`** | `~/.oci/config` API key | File on disk | Fast dev / debugging |
| **CI pipeline** | API key or workload identity | Secrets store | Nightly / gated applies |
