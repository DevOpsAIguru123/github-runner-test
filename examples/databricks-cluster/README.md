# Databricks Cluster — Terraform via AKS Self-Hosted Runner

Deploy a Databricks cluster using Terraform running inside an AKS self-hosted runner pod authenticated via AKS Workload Identity.

---

## Table of Contents

1. [Architecture](#1-architecture)
2. [Prerequisites](#2-prerequisites)
3. [Setup Steps](#3-setup-steps)
4. [How Authentication Works](#4-how-authentication-works)
5. [Running the Workflow](#5-running-the-workflow)
6. [Authentication Issues & Fixes (Full Journey)](#6-authentication-issues--fixes-full-journey)
7. [Key Concepts](#7-key-concepts)

---

## 1. Architecture

```
GitHub Actions Workflow (runs-on: aks-runners)
         │
         ▼
AKS Runner Pod
  ├── AZURE_CLIENT_ID        ──┐
  ├── AZURE_TENANT_ID          ├── Injected by AKS WI mutating webhook
  ├── AZURE_FEDERATED_TOKEN_FILE ─┘
  │
  │ Step: Exchange WI token for AAD token
  │   curl → login.microsoftonline.com → POST client_credentials
  │             with JWT bearer assertion (the WI OIDC token)
  │             scoped to Databricks resource ID
  │   → sets DATABRICKS_TOKEN env var
  │
  ▼
Terraform (databricks provider)
  ├── host = databricks_host var
  └── reads DATABRICKS_TOKEN from env → authenticates to workspace
         │
         ▼
  Databricks Workspace (Azure)
  └── Creates / manages cluster
```

---

## 2. Prerequisites

### Azure side
- Databricks workspace (Azure-managed)
- User-assigned managed identity with:
  - Federated identity credential linked to the AKS cluster OIDC issuer
  - Subject: `system:serviceaccount:arc-runners:wi-runner-sa`
- Managed identity added as **admin** to the Databricks workspace

### Kubernetes side
- AKS cluster with `oidc_issuer_enabled = true` and `workload_identity_enabled = true`
- Service account `wi-runner-sa` in `arc-runners` namespace annotated with the managed identity client ID
- Runner pods with label `azure.workload.identity/use: "true"` (set in Helm values)

### GitHub side
- Workflow file `.github/workflows/deploy-databricks.yml`
- No additional secrets required — all auth flows through Workload Identity

---

## 3. Setup Steps

### Step 1 — Provision AKS with Workload Identity

```bash
cd terraform
terraform init && terraform apply
```

This creates the AKS cluster, user-assigned managed identity, Contributor role assignment, and federated identity credential. See `terraform/workload-identity.tf`.

### Step 2 — Add the managed identity to Databricks as admin

The managed identity needs to be a Databricks workspace admin to create/manage clusters.

1. Go to your Databricks workspace → **Settings → Identity and access → Service principals**
2. Click **Add service principal**
3. Enter the **Application (client) ID** of your managed identity: `81f11862-717d-4da8-b09d-c93f4e6ea9af`
4. Assign the **Admin** role to the service principal

> **Why admin?** Creating clusters requires workspace admin permissions. Without this, Terraform gets a 403 even with a valid token.

### Step 3 — Apply the Kubernetes service account

```bash
kubectl apply -f k8s/workload-identity-sa.yaml
```

This creates `wi-runner-sa` in `arc-runners` with the WI annotation. Verify:

```bash
kubectl get serviceaccount wi-runner-sa -n arc-runners -o yaml
# Should show annotation: azure.workload.identity/client-id: 81f11862-...
```

### Step 4 — Update Helm runner values and upgrade

`helm/arc-runner-set-values.yaml` must have the WI label and service account on the runner pod template:

```yaml
template:
  metadata:
    labels:
      azure.workload.identity/use: "true"
  spec:
    serviceAccountName: wi-runner-sa
    containers:
      - name: runner
        env:
          - name: ARM_SUBSCRIPTION_ID
            value: "<your-subscription-id>"
```

Apply:

```bash
helm upgrade --install aks-runners \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  --version 0.9.3 \
  --namespace arc-runners \
  --values helm/arc-runner-set-values.yaml
```

### Step 5 — Verify WI injection in a runner pod

Trigger any workflow and exec into the runner pod while it runs:

```bash
kubectl get pods -n arc-runners -w
kubectl exec -it <runner-pod-name> -n arc-runners -- env | grep AZURE
```

Expected output:
```
AZURE_CLIENT_ID=81f11862-717d-4da8-b09d-c93f4e6ea9af
AZURE_TENANT_ID=342b3f4c-6303-47b1-bea2-e0c6b2200b67
AZURE_FEDERATED_TOKEN_FILE=/var/run/secrets/azure/tokens/azure-identity-token
AZURE_AUTHORITY_HOST=https://login.microsoftonline.com/
```

### Step 6 — Run the workflow

Go to **Actions → Deploy Databricks Cluster → Run workflow** and select `plan`, `apply`, or `destroy`.

---

## 4. How Authentication Works

AKS Workload Identity is OIDC-based federated identity. The flow for Databricks authentication:

```
1. AKS OIDC issuer signs a service account token for the runner pod
   → mounted at AZURE_FEDERATED_TOKEN_FILE
   → this is a short-lived JWT (audience: api://AzureADTokenExchange)

2. Workflow step reads the JWT and calls Azure AD token endpoint:
   POST https://login.microsoftonline.com/<TENANT_ID>/oauth2/v2.0/token
     grant_type = client_credentials
     client_id = <AZURE_CLIENT_ID>          (managed identity client ID)
     client_assertion_type = urn:ietf:params:oauth:client-assertion-type:jwt-bearer
     client_assertion = <WI OIDC JWT>       (the federated token)
     scope = 2ff814a6-3304-4ab8-85cb-cd0e6f879c1d/.default
             ↑ this is the Databricks Azure resource ID

3. Azure AD validates:
   - JWT signature against AKS OIDC issuer public keys
   - JWT issuer matches the federated credential's configured issuer
   - JWT subject matches system:serviceaccount:arc-runners:wi-runner-sa
   → Issues an Azure AD access token scoped to Databricks

4. Workflow exports: DATABRICKS_TOKEN=<azure-ad-access-token>

5. Terraform databricks provider reads DATABRICKS_TOKEN from env
   → Authenticates all API calls with this bearer token
   → No secrets, no PATs, no client secrets stored anywhere
```

### Why the Databricks resource ID `2ff814a6-...`?

This is the fixed Azure resource ID for all Azure Databricks workspaces globally. When you request a token scoped to this resource, Azure AD issues a token that Databricks will accept as a valid AAD bearer token — regardless of which specific workspace you target. The `host` in the provider config then routes the calls to your workspace.

---

## 5. Running the Workflow

The workflow at `.github/workflows/deploy-databricks.yml` supports three actions:

| Action | Effect |
|--------|--------|
| `plan` | Runs `terraform plan` — shows what would be created/changed |
| `apply` | Runs `terraform plan` then `terraform apply` — creates/updates the cluster |
| `destroy` | Runs `terraform destroy` — deletes the cluster |

**Trigger:** Go to **Actions → Deploy Databricks Cluster → Run workflow → Choose action → Run workflow**

**Monitor:**
```bash
# Watch runner pod
kubectl get pods -n arc-runners -w

# View logs
kubectl logs -n arc-runners <runner-pod-name> -f
```

**Verify cluster was created:**
Go to your Databricks workspace → **Compute** → look for `aks-runner-cluster`.

---

## 6. Authentication Issues & Fixes (Full Journey)

The path to working Databricks authentication from AKS runners was non-trivial. Here is every approach tried and why it failed, along with the working solution.

---

### Issue 1: Managed identity not added to Databricks workspace
**Symptom:**
```
Error: cannot create cluster: 403 Forbidden
```
**Cause:** The managed identity existed and had Azure Contributor role, but was not added as a service principal inside the Databricks workspace. Azure RBAC and Databricks workspace permissions are separate systems.

**Fix:** Add the managed identity (by client ID) as an **Admin** service principal in Databricks workspace settings. See [Step 2](#step-2--add-the-managed-identity-to-databricks-as-admin) above.

---

### Issue 2: `azure_use_oidc = true` — unsupported argument
**Symptom:**
```
Error: Unsupported argument: An argument named "azure_use_oidc" is not expected here.
```
**Cause:** `azure_use_oidc` is not a valid Databricks provider argument. It is valid for the `azurerm` provider.

**Fix:** Remove `azure_use_oidc`. The Databricks provider has its own authentication attributes.

---

### Issue 3: `autotermination_minutes` — wrong attribute name
**Symptom:**
```
Error: Unsupported argument: An argument named "auto_termination_minutes" is not expected here.
```
**Cause:** Terraform attribute naming inconsistency. The Databricks provider uses `autotermination_minutes` (no underscore after `auto`).

**Fix:** Change `auto_termination_minutes` to `autotermination_minutes` in `main.tf`.

---

### Issue 4: Old Databricks provider version — no AKS WI support
**Symptom:**
```
Error: cannot configure default credentials
```
**Cause:** Databricks provider v1.38 predates AKS Workload Identity support. The auth chain had no path for WI federated tokens.

**Fix:** Upgrade provider to `~> 1.85` in `providers.tf`:
```hcl
required_providers {
  databricks = {
    source  = "databricks/databricks"
    version = "~> 1.85"
  }
}
```

---

### Issue 5: `azure_federated_token_file` — not activating WI auth chain
**Provider config tried:**
```hcl
provider "databricks" {
  host                        = var.databricks_host
  azure_workspace_resource_id = var.databricks_workspace_resource_id
  azure_client_id             = var.managed_identity_client_id
  azure_federated_token_file  = "/var/run/secrets/azure/tokens/azure-identity-token"
}
```
**Symptom:**
```
Error: cannot configure default credentials
Config: host=..., azure_client_id=..., azure_workspace_resource_id=...
```
**Cause:** The `azure_federated_token_file` attribute is intended for GitHub Actions OIDC, not AKS Workload Identity. The provider's internal Go SDK maps this through a different auth path that expects a GitHub OIDC audience (`https://token.actions.githubusercontent.com`), not AKS (`api://AzureADTokenExchange`). The WI credential chain silently falls through.

**Fix (wrong):** Does not work for AKS WI.

---

### Issue 6: `azure_use_msi = true` — hits IMDS node identity, not pod WI identity
**Provider config tried:**
```hcl
provider "databricks" {
  host            = var.databricks_host
  azure_client_id = var.managed_identity_client_id
  azure_use_msi   = true
}
```
**Symptom:**
```
Error: cannot configure default credentials
Config: host=..., azure_use_msi=true, azure_client_id=..., azure_tenant_id=...
```
**Cause:** `azure_use_msi = true` activates the Managed Identity credential path which calls the Azure Instance Metadata Service (IMDS) at `http://169.254.169.254/metadata/identity`. In AKS pods, the IMDS endpoint is accessible but returns the **node's** system-assigned managed identity, not the pod's user-assigned WI identity. The user-assigned managed identity client ID is ignored in IMDS calls unless it maps to an identity attached to the underlying VM — which it doesn't (it's a federated WI identity, not a VM-attached identity).

**Fix (wrong):** Does not work for AKS WI pod identity.

---

### Issue 7: `DATABRICKS_AAD_TOKEN` — unrecognized env var
**Approach tried:** Manual token exchange in workflow step, exporting result as `DATABRICKS_AAD_TOKEN`.

**Symptom:** Auth still failed — provider showed no token in its config output.

**Cause:** `DATABRICKS_AAD_TOKEN` is not a recognized environment variable in the Databricks Go SDK or Terraform provider. The SDK reads the token from `DATABRICKS_TOKEN` regardless of whether it is a PAT or an Azure AD bearer token.

**Fix:** Change the env var name from `DATABRICKS_AAD_TOKEN` to `DATABRICKS_TOKEN`.

---

### Issue 8 (Resolved): Manual token exchange with `DATABRICKS_TOKEN`
**Working approach:**

Workflow step before Terraform:
```bash
OIDC_TOKEN=$(cat "${AZURE_FEDERATED_TOKEN_FILE}")
RESPONSE=$(curl -s -X POST \
  "https://login.microsoftonline.com/${AZURE_TENANT_ID}/oauth2/v2.0/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "client_id=${AZURE_CLIENT_ID}" \
  --data-urlencode "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  --data-urlencode "client_assertion=${OIDC_TOKEN}" \
  --data-urlencode "scope=2ff814a6-3304-4ab8-85cb-cd0e6f879c1d/.default")
TOKEN=$(echo "$RESPONSE" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
echo "DATABRICKS_TOKEN=${TOKEN}" >> $GITHUB_ENV
```

Provider config (simplified to just `host`):
```hcl
provider "databricks" {
  host = var.databricks_host
}
```

**Why this works:**
- `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_FEDERATED_TOKEN_FILE` are all injected by the AKS WI webhook — no secrets needed
- The token exchange uses the standard OAuth 2.0 client credentials flow with JWT bearer assertion (RFC 7523)
- Azure AD validates the JWT against the AKS OIDC issuer public keys
- The resulting token is a standard Azure AD bearer token that Databricks accepts
- `DATABRICKS_TOKEN` is the correct env var name — the provider reads it automatically

---

### Summary: What Does and Doesn't Work

| Approach | Result | Reason |
|----------|--------|--------|
| `azure_use_oidc = true` | ❌ Unsupported argument | Not a valid Databricks provider attr |
| `azure_federated_token_file` | ❌ Auth fails | GitHub OIDC audience, not AKS WI |
| `azure_use_msi = true` | ❌ Auth fails | IMDS returns node identity, not pod WI identity |
| `DATABRICKS_AAD_TOKEN` env var | ❌ Not recognized | Wrong env var name |
| Manual exchange → `DATABRICKS_TOKEN` | ✅ Works | Correct env var; explicit AAD token exchange |

---

## 7. Key Concepts

### AKS Workload Identity vs Managed Identity (IMDS)

| | AKS Workload Identity | VM Managed Identity (IMDS) |
|--|---|---|
| Auth mechanism | OIDC federation — short-lived JWT, no long-lived secret | IMDS endpoint at `169.254.169.254` |
| Scope | Pod-level identity | Node/VM-level identity |
| Token type | Federated credential JWT | Azure AD access token directly from IMDS |
| Used with | `azure_federated_token_file` + token exchange | `azure_use_msi = true` |
| Works in AKS pods? | Yes (WI webhook injection) | Partially (returns node identity) |

### Databricks Resource ID

The fixed Azure resource ID `2ff814a6-3304-4ab8-85cb-cd0e6f879c1d` is the globally registered application ID for Azure Databricks. When requesting an OAuth 2.0 token, using `scope=2ff814a6-.../.default` tells Azure AD to issue a token that grants access to any Azure Databricks workspace the identity has been granted access to. The specific workspace is then determined by the `host` parameter in the provider config.

### Why No `azure_workspace_resource_id` Is Needed

`azure_workspace_resource_id` is required when the provider uses Azure AD auth flows that need to resolve the workspace tenant from the ARM resource. When using `DATABRICKS_TOKEN` (a pre-obtained AAD token), the token already encodes the tenant and the workspace is fully identified by `host` alone. Setting `azure_workspace_resource_id` adds no value and can cause confusion.

### Token Lifetime

WI OIDC tokens are short-lived (typically 1 hour). The token exchange in the workflow runs fresh at the start of each job, so the `DATABRICKS_TOKEN` is always valid for the duration of the Terraform run. No rotation logic is needed.
