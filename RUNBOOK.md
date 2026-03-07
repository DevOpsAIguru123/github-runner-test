# AKS GitHub Self-Hosted Runners — Operational Runbook

> **Purpose:** Step-by-step instructions for provisioning, deploying, operating, and tearing down AKS-based GitHub Actions self-hosted runners with Workload Identity.
>
> **Audience:** DevOps engineers deploying or maintaining this system.
>
> **Repo:** `DevOpsAIguru123/github-runner-test`

---

## Prerequisites Checklist

Before starting, confirm you have:

- [ ] Azure subscription with **Owner** or **Contributor + User Access Administrator** role
- [ ] [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5 installed
- [ ] [Azure CLI](https://docs.microsoft.com/cli/azure/install-azure-cli) installed and logged in (`az login`)
- [ ] [kubectl](https://kubernetes.io/docs/tasks/tools/) installed
- [ ] [Helm](https://helm.sh/docs/intro/install/) >= 3.x installed
- [ ] GitHub PAT with `repo` scope (classic token) for `DevOpsAIguru123/github-runner-test`
- [ ] [GitHub CLI](https://cli.github.com/) (`gh`) installed and authenticated (`gh auth login`)

---

## Part 1 — Provision AKS Cluster

### Step 1.1 — Log in to Azure

```bash
az login
az account show   # verify correct subscription
```

If you need to switch subscriptions:
```bash
az account set --subscription "<SUBSCRIPTION_NAME_OR_ID>"
```

### Step 1.2 — Initialize and apply Terraform

```bash
cd terraform
terraform init
terraform plan    # review what will be created
terraform apply   # type 'yes' when prompted
```

**What gets created:**
- Resource Group: `rg-github-runners`
- AKS Cluster: `aks-github-runners` (public API server, kubenet, 1-3 × Standard_D2s_v3)
- User-Assigned Managed Identity: `mi-aks-github-runners-runner`
- Contributor role assignment on subscription
- Federated Identity Credential linked to K8s service account `arc-runners/wi-runner-sa`

### Step 1.3 — Save Terraform outputs

```bash
terraform output managed_identity_client_id   # → AZURE_CLIENT_ID
terraform output tenant_id                    # → AZURE_TENANT_ID
terraform output subscription_id              # → AZURE_SUBSCRIPTION_ID
```

Keep these values — you will need them in Part 3.

### Step 1.4 — Configure kubectl

```bash
$(terraform output -raw get_credentials_command)
# Runs: az aks get-credentials --resource-group rg-github-runners \
#                               --name aks-github-runners --overwrite-existing

kubectl get nodes   # verify: nodes should be Ready
```

---

## Part 2 — Deploy GitHub Actions Runners (ARC)

### Step 2.1 — Set environment variables

```bash
export GITHUB_PAT="ghp_xxxxxxxxxxxxxxxxxxxx"
export GITHUB_OWNER="DevOpsAIguru123"
export GITHUB_REPO="github-runner-test"
export MANAGED_IDENTITY_CLIENT_ID="$(cd terraform && terraform output -raw managed_identity_client_id)"
```

### Step 2.2 — Run the deployment script

```bash
cd ..   # back to repo root
./scripts/deploy-runners.sh
```

The script performs:
1. Creates `arc-systems` namespace
2. Creates `arc-runners` namespace
3. Creates `github-pat-secret` Kubernetes secret with your PAT
4. Helm installs `arc-controller` (ARC controller) in `arc-systems`
5. Helm installs `aks-runners` (runner scale set) in `arc-runners`
6. Creates `wi-runner-sa` Kubernetes service account with Workload Identity annotation

### Step 2.3 — Verify ARC controller is running

```bash
kubectl get pods -n arc-systems
```

Expected output:
```
NAME                                                READY   STATUS    RESTARTS   AGE
aks-runners-<hash>-listener                         1/1     Running   0          30s
arc-controller-gha-rs-controller-<hash>             1/1     Running   0          60s
```

> If the listener is in `Error` or `CrashLoopBackOff`, see [Troubleshooting Issue 12](TROUBLESHOOTING.md#issue-12).

### Step 2.4 — Verify runner appears online in GitHub

Navigate to: **GitHub → DevOpsAIguru123/github-runner-test → Settings → Actions → Runners**

You should see `aks-runners` with status **Idle** (not Offline).

> If Offline, check listener logs: `kubectl logs -n arc-systems -l actions.github.com/scale-set-name=aks-runners`

---

## Part 3 — Configure GitHub Environment Variables

### Step 3.1 — Create the `dev` environment in GitHub

1. Go to **GitHub → Settings → Environments**
2. Click **New environment** → name it `dev`
3. Click **Configure environment**

### Step 3.2 — Add Variables (not Secrets)

Under **Environment variables**, add:

| Variable Name | Value |
|---|---|
| `AZURE_CLIENT_ID` | Value from `terraform output managed_identity_client_id` |
| `AZURE_TENANT_ID` | Value from `terraform output tenant_id` |
| `AZURE_SUBSCRIPTION_ID` | Value from `terraform output subscription_id` |

> These are **Variables** (plain text), not Secrets. They appear as `${{ vars.AZURE_CLIENT_ID }}` in workflows.

---

## Part 4 — Apply Workload Identity Kubernetes Service Account

### Step 4.1 — Patch and apply the service account

```bash
MANAGED_IDENTITY_CLIENT_ID=$(cd terraform && terraform output -raw managed_identity_client_id)

sed "s/<MANAGED_IDENTITY_CLIENT_ID>/${MANAGED_IDENTITY_CLIENT_ID}/" \
  k8s/workload-identity-sa.yaml | kubectl apply -f -
```

### Step 4.2 — Verify the service account

```bash
kubectl get sa wi-runner-sa -n arc-runners -o yaml
```

Confirm the annotation is present:
```yaml
annotations:
  azure.workload.identity/client-id: "<your-client-id>"
```

### Step 4.3 — Upgrade Helm runner set to use the WI service account

```bash
helm upgrade aks-runners \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  --version 0.9.3 \
  --namespace arc-runners \
  --values helm/arc-runner-set-values.yaml
```

Confirm the upgrade succeeded:
```bash
helm list -n arc-runners
# REVISION should increment, STATUS = deployed
```

---

## Part 5 — Test: Deploy Storage Account via Workflow

### Step 5.1 — Trigger a plan run

1. Go to **GitHub → Actions → Deploy Storage Account**
2. Click **Run workflow**
3. Select `action = plan`
4. Click **Run workflow**

### Step 5.2 — Monitor the run

Watch the **Verify Workload Identity token** step output. Confirm:
- `ARM_OIDC_TOKEN_FILE_PATH` is set to `/var/run/secrets/azure/tokens/azure-identity-token`
- `Token file: present at ...` (not the ERROR line)
- Token claims show correct `iss` (AKS OIDC URL), `sub` (`system:serviceaccount:arc-runners:wi-runner-sa`), `aud` (`api://AzureADTokenExchange`)

Watch the **Terraform Plan** step — it should authenticate successfully and show a plan without errors.

### Step 5.3 — Apply (deploy the storage account)

1. Trigger the workflow again with `action = apply`
2. Terraform will create:
   - Resource Group: `rg-demo-storage`
   - Storage Account: `staksrunnersdemo` (LRS, TLS 1.2, versioning enabled)

### Step 5.4 — Verify in Azure

```bash
az storage account show \
  --name staksrunnersdemo \
  --resource-group rg-demo-storage \
  --output table
```

---

## Part 6 — Day-2 Operations

### Upgrade ARC to a new version

```bash
# Check current versions
helm list -n arc-systems
helm list -n arc-runners

# Upgrade controller
helm upgrade arc-controller \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller \
  --version <NEW_VERSION> \
  --namespace arc-systems \
  --values helm/arc-controller-values.yaml

# Upgrade runner set
helm upgrade aks-runners \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  --version <NEW_VERSION> \
  --namespace arc-runners \
  --values helm/arc-runner-set-values.yaml
```

> Always upgrade the controller first, then the runner set.
> Always pass `--values helm/arc-runner-set-values.yaml` — never omit it, or Helm will reset to defaults and break the GitHub URL.

### Rotate GitHub PAT

```bash
export GITHUB_PAT="ghp_new_token_here"

kubectl create secret generic github-pat-secret \
  --namespace arc-runners \
  --from-literal=github_token="${GITHUB_PAT}" \
  --dry-run=client -o yaml | kubectl apply -f -

# Restart listener to pick up the new token
kubectl rollout restart deployment arc-controller-gha-rs-controller -n arc-systems
```

### Scale node pool manually

```bash
az aks nodepool scale \
  --resource-group rg-github-runners \
  --cluster-name aks-github-runners \
  --name systempool \
  --node-count 3
```

### Re-configure kubectl after cluster recreation

```bash
# If az aks get-credentials fails with config errors:
mv ~/.kube/config ~/.kube/config.bak
az aks get-credentials \
  --resource-group rg-github-runners \
  --name aks-github-runners \
  --overwrite-existing
```

### Cancel a stuck GitHub Actions run

```bash
gh run list --repo DevOpsAIguru123/github-runner-test --limit 10
gh run cancel <RUN_ID> --repo DevOpsAIguru123/github-runner-test
```

### Delete a stuck EphemeralRunner

```bash
kubectl get ephemeralrunners -n arc-runners
kubectl delete ephemeralrunner <NAME> -n arc-runners --force --grace-period=0
```

---

## Part 7 — Tear Down

### Step 7.1 — Destroy the demo storage account (optional)

Trigger the workflow with `action = destroy`, or:
```bash
cd examples/storage-account
terraform destroy -auto-approve
```

### Step 7.2 — Uninstall ARC Helm releases

```bash
helm uninstall aks-runners -n arc-runners
helm uninstall arc-controller -n arc-systems
```

### Step 7.3 — Delete Kubernetes namespaces

```bash
kubectl delete namespace arc-runners
kubectl delete namespace arc-systems
```

### Step 7.4 — Destroy AKS cluster and all Azure resources

```bash
cd terraform
terraform destroy -auto-approve
```

This removes: AKS cluster, resource group, managed identity, role assignment, federated credential.

---

## Quick Reference — Status Checks

```bash
# Is the ARC controller healthy?
kubectl get pods -n arc-systems

# Is the listener connected to GitHub?
kubectl logs -n arc-systems -l actions.github.com/scale-set-name=aks-runners --tail=20

# Are there any runner pods running right now?
kubectl get pods -n arc-runners

# What is the current runner autoscaling state?
kubectl get autoscalingrunnersets -n arc-runners
kubectl get ephemeralrunnersets -n arc-runners

# What Helm releases are deployed?
helm list -n arc-systems
helm list -n arc-runners

# Recent error events
kubectl get events -n arc-runners --sort-by='.lastTimestamp' | tail -20
kubectl get events -n arc-systems --sort-by='.lastTimestamp' | tail -20
```

---

## Architecture Summary

```
GitHub Actions workflow (runs-on: aks-runners)
          │
          ▼ long-poll
  ARC Listener Pod (arc-systems)
          │
          │ job queued → creates EphemeralRunner CRD
          ▼
  ARC Controller Pod (arc-systems)
          │
          │ creates pod using wi-runner-sa service account
          ▼
  Runner Pod (arc-runners)
    ├── WI Mutating Webhook injects:
    │     AZURE_FEDERATED_TOKEN_FILE → /var/run/secrets/azure/tokens/azure-identity-token
    │     AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_AUTHORITY_HOST
    ├── Helm values inject:
    │     ARM_OIDC_TOKEN_FILE_PATH → same path (read by azurerm Terraform provider)
    └── Executes workflow steps:
          terraform init / plan / apply
                │
                │ OIDC token exchange (no client secret)
                ▼
          Azure Resource Manager API
```

---

> For detailed issue analysis and fixes, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
