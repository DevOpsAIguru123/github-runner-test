# AKS GitHub Self-Hosted Runners — Full Setup Guide & Troubleshooting

## Table of Contents
1. [System Architecture](#1-system-architecture)
2. [End-to-End Workflow](#2-end-to-end-workflow)
3. [Step-by-Step Setup](#3-step-by-step-setup)
4. [Issues Encountered & Fixes](#4-issues-encountered--fixes)
   - [Issue 8: `node` not found — setup-terraform wrapper](#issue-8-node-no-such-file-or-directory-when-running-terraform-in-workflow)
   - [Issue 9: azurerm falls back to Azure CLI — OIDC token file mismatch](#issue-9-terraform-azurerm-provider-falls-back-to-azure-cli--az-not-found)
   - [Issue 10: GitHub environment variables not injected](#issue-10-github-environment-scoped-variables-not-injected-into-workflow)
   - [Issue 11: `helm upgrade` fails — no deployed releases](#issue-11-helm-upgrade-fails--has-no-deployed-releases)
   - [Issue 12: Runner offline after helm upgrade (placeholder URL)](#issue-12-runner-goes-offline-after-helm-upgrade-placeholder-url-in-values-file)
5. [Key Concepts Reference](#5-key-concepts-reference)

---

## 1. System Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        GITHUB                                    │
│                                                                  │
│  Workflow (runs-on: aks-runners)                                 │
│       │                                                          │
│       ▼                                                          │
│  GitHub Actions Queue ◄──────── ARC Listener (long-poll)        │
│       │                              ▲                           │
│       │ job assigned                 │ scale request             │
│       ▼                              │                           │
│  Runner Scale Set (aks-runners)      │                           │
└──────────────────────────────────────┼──────────────────────────┘
                                       │
                    ┌──────────────────┼──────────────────────────┐
                    │   AKS CLUSTER    │                           │
                    │                  │                           │
                    │  arc-systems namespace                       │
                    │  ┌───────────────────────────────────────┐  │
                    │  │  ARC Controller Pod                   │  │
                    │  │  (gha-runner-scale-set-controller)    │  │
                    │  │                                       │  │
                    │  │  Listener Pod (aks-runners-*-listener)│  │
                    │  │  - Long-polls GitHub for jobs         │  │
                    │  │  - Scales EphemeralRunnerSet          │  │
                    │  └───────────────────────────────────────┘  │
                    │                                              │
                    │  arc-runners namespace                       │
                    │  ┌───────────────────────────────────────┐  │
                    │  │  Runner Pod (ephemeral)                │  │
                    │  │  - Created per job                    │  │
                    │  │  - Runs workflow steps                 │  │
                    │  │  - Terminated after job completes     │  │
                    │  └───────────────────────────────────────┘  │
                    │                                              │
                    └──────────────────────────────────────────────┘
```

**Key components:**

| Component | Namespace | Purpose |
|-----------|-----------|---------|
| ARC Controller | `arc-systems` | Manages runner lifecycle, reconciles CRDs |
| Listener Pod | `arc-systems` | Long-polls GitHub API for job queue events |
| Runner Pod | `arc-runners` | Executes the actual workflow job steps |
| `github-pat-secret` | `arc-runners` | Kubernetes secret storing GitHub PAT |

---

## 2. End-to-End Workflow

### From `terraform apply` to workflow completion

```
Step 1: Terraform provisions AKS
        terraform apply
             │
             ▼
        Azure creates:
        - Resource Group
        - AKS Cluster (public, kubenet, 1-3 nodes)
        - System-assigned Managed Identity
        - Load Balancer

Step 2: Configure kubectl
        az aks get-credentials --resource-group rg-github-runners \
                               --name aks-github-runners

Step 3: Deploy ARC Controller (Helm)
        helm install arc-controller \
          oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller
             │
             ▼
        Controller pod starts in arc-systems
        Watches for AutoscalingRunnerSet CRDs

Step 4: Create GitHub PAT secret
        kubectl create secret generic github-pat-secret \
          --namespace arc-runners \
          --from-literal=github_token=<PAT>

Step 5: Deploy Runner Scale Set (Helm)
        helm install aks-runners \
          oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
          --set githubConfigUrl=https://github.com/OWNER/REPO
             │
             ▼
        Controller creates:
        - AutoscalingRunnerSet CRD
        - EphemeralRunnerSet CRD
        - Listener Pod in arc-systems

Step 6: Listener connects to GitHub
        Listener pod registers the scale set with GitHub
        GitHub shows "aks-runners" as Online in repo settings
        minRunners=0 → no runner pods yet (idle state)

Step 7: Developer pushes code / triggers workflow
        .github/workflows/test.yml with runs-on: aks-runners
             │
             ▼
        GitHub queues the job for "aks-runners" scale set

Step 8: Listener detects job
        Listener receives job assignment via long-poll
        Listener calls GitHub API to get JIT (Just-In-Time) token
        Listener creates EphemeralRunner CRD with embedded JIT token

Step 9: Controller creates Runner Pod
        Controller reads EphemeralRunner CRD
        Creates Kubernetes Secret with JIT token
        Creates Runner Pod with ACTIONS_RUNNER_INPUT_JITCONFIG env var

Step 10: Runner Pod starts
         Pod pulls ghcr.io/actions/actions-runner:latest
         Runner binary reads JIT config
         Registers with GitHub as a one-time ephemeral runner
         Picks up the assigned job

Step 11: Job executes
         Runner clones repo
         Executes each workflow step
         Sends logs back to GitHub Actions UI

Step 12: Job completes
         Runner reports success/failure to GitHub
         Runner pod exits (ephemeral — designed to run one job)
         Pod is terminated and cleaned up
         Listener scales EphemeralRunnerSet back to 0

Step 13: Next job → repeat from Step 7
```

---

## 3. Step-by-Step Setup

### Prerequisites
- Azure subscription with Contributor access
- Terraform >= 1.5
- Azure CLI (`az login` completed)
- kubectl
- Helm >= 3.x
- GitHub PAT with `repo` scope (classic) or Actions+Administration (fine-grained)

### 3.1 Provision AKS

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars if needed

terraform init
terraform apply
```

The cluster is configured with:
- `private_cluster_enabled = false` — API server reachable from internet
- No `api_server_authorized_ip_ranges` — no IP restrictions
- `network_plugin = "kubenet"` — no VNet pre-setup required
- `oidc_issuer_enabled = true` — supports Workload Identity if needed later
- Node autoscaling: 1–3 × `Standard_D2s_v3`

### 3.2 Configure kubectl

```bash
$(terraform output -raw get_credentials_command)
# Equivalent to:
az aks get-credentials --resource-group rg-github-runners \
  --name aks-github-runners --overwrite-existing

kubectl get nodes   # verify cluster access
```

> **Common issue:** If `~/.kube/config` is empty/corrupted, back it up:
> ```bash
> mv ~/.kube/config ~/.kube/config.bak
> az aks get-credentials ...
> ```

### 3.3 Deploy Runners

```bash
export GITHUB_PAT=ghp_xxxxxxxxxxxx
export GITHUB_OWNER=your-username-or-org
export GITHUB_REPO=your-repo

./scripts/deploy-runners.sh
```

The script:
1. Creates `arc-systems` and `arc-runners` namespaces
2. Stores PAT as a Kubernetes secret
3. Installs ARC controller via Helm
4. Installs runner scale set via Helm

### 3.4 Verify

```bash
# Controller and listener pods should be Running
kubectl get pods -n arc-systems

# No runner pods at idle (minRunners=0 is expected)
kubectl get pods -n arc-runners

# Should show aks-runners as Online
# → https://github.com/OWNER/REPO/settings/actions/runners
```

### 3.5 Test

```yaml
# .github/workflows/test.yml
name: Test AKS Runner
on: [push]
jobs:
  test:
    runs-on: aks-runners
    steps:
      - uses: actions/checkout@v4
      - run: echo "Hello from AKS $(hostname)!"
```

```bash
# Watch runner pod appear when job queues
kubectl get pods -n arc-runners -w
```

---

## 4. Issues Encountered & Fixes

### Issue 1: `~/.kube/config` corrupted
**Symptom:**
```
No such key 'clusters' in existing config
```
**Cause:** The kubeconfig file existed but was empty or malformed.

**Fix:**
```bash
mv ~/.kube/config ~/.kube/config.bak
az aks get-credentials --resource-group rg-github-runners \
  --name aks-github-runners --overwrite-existing
```

---

### Issue 2: Listener pod not appearing in `arc-runners`
**Symptom:**
```
kubectl get pods -n arc-runners
No resources found in arc-runners namespace.
```
**Cause:** Misunderstanding of ARC v2 architecture. The listener pod lives in `arc-systems`, not `arc-runners`. `arc-runners` only has pods when a job is actively running.

**Fix:** Check the correct namespace:
```bash
kubectl get pods -n arc-systems   # listener is here
kubectl get pods -n arc-runners   # runner pods appear only when jobs run
```

---

### Issue 3: Runner pods cycling — "Waiting for a runner to pick up this job"
**Symptom:**
- Runner pods repeatedly create → `Completed` → restart (every 16–55 seconds)
- GitHub showed "Waiting for a runner to pick up this job"
- `kubectl get ephemeralrunners -n arc-runners` showed `STATUS: Failed`

**Root cause 1 — `containerMode: kubernetes` failing silently:**
In kubernetes container mode, the runner pod acts as an orchestrator that creates sub-pods for each step. This requires RBAC permissions and a working PVC. Without those, the runner exits with code 0 (no error), registering with GitHub but immediately exiting before picking up the job.

**Fix 1:** Switch from kubernetes container mode to default mode (runner executes steps directly inside the pod). Remove the `containerMode` block from `arc-runner-set-values.yaml`:

```yaml
# REMOVED:
# containerMode:
#   type: "kubernetes"
#   kubernetesModeWorkVolumeClaim: ...

# KEPT: simple runner template
template:
  spec:
    containers:
      - name: runner
        image: ghcr.io/actions/actions-runner:latest
```

---

### Issue 4: Stale job assignments blocking new runs
**Symptom:**
- After upgrading Helm release, GitHub still showed `totalBusyRunners: 1` and `totalAssignedJobs: 1`
- New runner pods started and immediately exited — they couldn't claim the job
- Listener logs showed `patchID` incrementing endlessly

**Root cause:** GitHub had assigned a job to the **old** runner scale set (pre-upgrade). JIT tokens are single-use — once consumed (or tied to a stale runner ID), subsequent runner pods registered with a new runner ID and found nothing to claim.

**Fix:** Cancel the stale GitHub Actions run, then trigger a fresh one:
```bash
gh run cancel <RUN_ID> --repo OWNER/REPO

git commit --allow-empty -m "trigger: fresh run" && git push
```

---

### Issue 5: Failed EphemeralRunner blocking the controller
**Symptom:**
- `kubectl get ephemeralrunners -n arc-runners` showed `STATUS: Failed`
- Message: `Pod has failed to start more than 5 times`
- No new runner pods were being created

**Root cause:** After 5 pod failures, the controller marks the EphemeralRunner as permanently failed and stops retrying. The listener kept requesting replicas, but the controller couldn't create new pods because the failed runner was still counted.

**Fix:** Manually delete the stuck EphemeralRunner to force the controller to create a fresh one with a new JIT token:
```bash
kubectl delete ephemeralrunner <NAME> -n arc-runners --force --grace-period=0
```

---

### Issue 6: Runner pod exits in <1 second with zero log output (root cause)
**Symptom:**
- Runner pod starts → `Completed` in 1 second
- `kubectl logs` returns nothing
- Exit code 0 (no error)
- `kubectl get ephemeralrunner -n arc-runners` showed `STATUS: Failed` after 5 retries

**Investigation steps:**
```
1. Network test → GitHub API reachable (curl returned 200) ✓
2. Image test → Runner binary works when invoked explicitly ✓
3. JIT config test → ACTIONS_RUNNER_INPUT_JITCONFIG was being injected ✓
4. Listener logs → Job IS being assigned to scale set ✓
5. Decoded JIT config → Valid base64 JSON structure ✓
6. Running run.sh explicitly → Produced full runner output ✓
   → DISCOVERY: Default ENTRYPOINT doesn't invoke run.sh!
```

**Root cause:** **Runner `v2.332.0`** (released Feb 2026) changed the container `ENTRYPOINT`. When the ARC controller creates the runner pod without an explicit `command`, the default entrypoint no longer automatically calls `run.sh` in JIT config mode. The container starts, finds no action to take via the default entrypoint, and exits cleanly with code 0.

Additionally, the runner binary writes logs to stderr by default. Without `2>&1`, `kubectl logs` shows nothing even when the runner is running.

**Fix:** Explicitly set `command` and `args` in `arc-runner-set-values.yaml`:

```yaml
template:
  spec:
    containers:
      - name: runner
        image: ghcr.io/actions/actions-runner:latest
        command: ["/bin/bash", "-c"]          # override ENTRYPOINT
        args: ["/home/runner/run.sh 2>&1"]    # call run.sh, redirect stderr→stdout
        env:
          - name: ACTIONS_RUNNER_PRINT_LOG_TO_STDOUT
            value: "1"
```

**Why `2>&1` matters:** The runner binary (`bin/Runner.Listener`) writes diagnostic logs to **stderr**. Redirecting stderr to stdout (`2>&1`) ensures `kubectl logs` captures all runner output, which is essential for debugging.

---

### Issue 7: `gh auth` — PAT returning 401 on runners API
**Symptom:**
```json
{"message": "Bad credentials", "status": "401"}
```
**Cause:** The `GITHUB_PAT` environment variable in the terminal was different from (or expired compared to) the PAT stored in the Kubernetes secret.

**Fix:** Re-export the correct PAT and update the Kubernetes secret:
```bash
export GITHUB_PAT=ghp_your_valid_token

kubectl create secret generic github-pat-secret \
  --namespace arc-runners \
  --from-literal=github_token="${GITHUB_PAT}" \
  --dry-run=client -o yaml | kubectl apply -f -

# Restart listener to pick up new credentials
kubectl rollout restart deployment arc-controller-gha-rs-controller -n arc-systems
```

---

### Issue 8: `node: No such file or directory` when running Terraform in workflow
**Symptom:**
```
/usr/bin/env: 'node': No such file or directory
Error: Process completed with exit code 127.
```
Step: `Run terraform init`

**Cause:** `hashicorp/setup-terraform@v3` by default wraps the `terraform` binary with a Node.js shim script so the action can capture step outputs. The self-hosted AKS runner container image (`ghcr.io/actions/actions-runner:latest`) does not have `node` in PATH, so the wrapper fails immediately.

**Fix:** Disable the wrapper in the workflow step:
```yaml
- name: Setup Terraform
  uses: hashicorp/setup-terraform@v3
  with:
    terraform_version: "~1.5"
    terraform_wrapper: false   # ← prevents node dependency
```
With `terraform_wrapper: false` the raw terraform binary is placed in PATH and invoked directly with no Node.js involved.

---

### Issue 9: Terraform azurerm provider falls back to Azure CLI — `az` not found
**Symptom:**
```
Error: unable to build authorizer for Resource Manager API:
  could not configure AzureCli Authorizer:
  could not parse Azure CLI version:
  launching Azure CLI: exec: "az": executable file not found in $PATH
```
**Cause:** The `azurerm` Terraform provider tries OIDC authentication but fails silently, then falls back to Azure CLI, which is also absent from the runner container.

OIDC fails because the provider reads the token file from `ARM_OIDC_TOKEN_FILE_PATH`, but AKS Workload Identity injects it under the env var `AZURE_FEDERATED_TOKEN_FILE`. These are **two different variable names** for the same file. Without `ARM_OIDC_TOKEN_FILE_PATH` being set, the provider cannot locate the token.

**Fix — set `ARM_OIDC_TOKEN_FILE_PATH` at the runner pod level (Helm):**

The WI webhook always mounts the token at a fixed path. Set this once in `helm/arc-runner-set-values.yaml` so every workflow inherits it automatically:

```yaml
template:
  spec:
    containers:
      - name: runner
        env:
          - name: ARM_OIDC_TOKEN_FILE_PATH
            value: "/var/run/secrets/azure/tokens/azure-identity-token"
```

Apply with:
```bash
helm upgrade aks-runners \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  --version 0.9.3 \
  --namespace arc-runners \
  --values helm/arc-runner-set-values.yaml
```

**AKS Workload Identity env var mapping:**

| Injected by WI webhook | Read by azurerm provider |
|---|---|
| `AZURE_FEDERATED_TOKEN_FILE` | `ARM_OIDC_TOKEN_FILE_PATH` |
| `AZURE_CLIENT_ID` | `ARM_CLIENT_ID` |
| `AZURE_TENANT_ID` | `ARM_TENANT_ID` |

---

### Issue 10: GitHub environment-scoped variables not injected into workflow
**Symptom:**
- `ARM_CLIENT_ID`, `ARM_TENANT_ID`, `ARM_SUBSCRIPTION_ID` are empty in the runner
- Workflow was created with variables scoped to a GitHub **environment** (e.g. `dev`) rather than repo-level variables

**Cause:** GitHub environment variables are only injected when the job explicitly declares `environment: <name>`. Without that declaration, the runner receives only repo-level variables and secrets.

**Fix:** Add `environment:` to the job in the workflow:
```yaml
jobs:
  terraform:
    runs-on: aks-runners
    environment: dev    # ← required to inject env-scoped variables
```

---

### Issue 11: `helm upgrade` fails — "has no deployed releases"
**Symptom:**
```
Error: UPGRADE FAILED: "arc-runner-set" has no deployed releases
```
**Cause:** Using a release name that was never successfully installed. The actual deployed release may have a different name.

**Fix:** List all releases to find the correct name, then upgrade that:
```bash
helm list -n arc-runners
helm list -n arc-systems
```

Use `--install` to handle both install and upgrade in one command:
```bash
helm upgrade --install <CORRECT-RELEASE-NAME> \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  --version 0.9.3 \
  --namespace arc-runners \
  --values helm/arc-runner-set-values.yaml
```

---

### Issue 12: Runner goes offline after `helm upgrade` (placeholder URL in values file)
**Symptom:**
- Listener pod starts then immediately crashes with:
  ```
  createSession failed: failed to get runner registration token on refresh:
  github api error: StatusCode 404, RequestID ...: {"message":"Not Found"}
  ```
- GitHub shows runner as Offline

**Cause:** `helm/arc-runner-set-values.yaml` still contained the placeholder `https://github.com/GITHUB_OWNER/GITHUB_REPO`. When `helm upgrade` was run using this file as `--values`, it overwrote the correct URL that the previous Helm revision had stored.

**Fix:** Replace the placeholder in the values file with the real repo URL before upgrading:
```yaml
# helm/arc-runner-set-values.yaml
githubConfigUrl: "https://github.com/DevOpsAIguru123/github-runner-test"
```

Then re-run the upgrade. The listener pod will restart and reconnect successfully.

> **Lesson:** Always commit the real `githubConfigUrl` value to the Helm values file. Do not leave placeholders in files that are used directly with `--values` in `helm upgrade`.

---

## 5. Key Concepts Reference

### ARC v2 JIT (Just-In-Time) Tokens
Each ephemeral runner gets a one-time JIT token generated by the listener when a job is queued. The token is embedded in an `EphemeralRunner` CRD and injected into the runner pod via a Kubernetes Secret. JIT tokens are **single-use** — once consumed (even if the runner fails), the same token cannot be reused. The controller creates a new `EphemeralRunner` (with a fresh token) for each retry.

### ARC v2 Autoscaling Mechanism
```
GitHub job queued
      │
      ▼
Listener detects via long-poll (MessageType: RunnerScaleSetJobMessages)
      │
      ▼
Listener updates EphemeralRunnerSet (desired replicas +1)
      │
      ▼
Controller creates EphemeralRunner CRD + JIT secret
      │
      ▼
Controller creates Runner Pod with JIT config
      │
      ▼
Runner registers with GitHub → picks up job → exits after completion
      │
      ▼
Controller deletes EphemeralRunner CRD + secret
      │
      ▼
Listener updates EphemeralRunnerSet (desired replicas -1)
```

### `minRunners: 0` Behavior
With `minRunners: 0`, the `arc-runners` namespace is **empty at idle**. This is correct and expected. A "listener pod" remains running in `arc-systems` (not `arc-runners`) — this pod maintains the long-poll connection to GitHub and doesn't consume significant resources.

Cost benefit: you only pay for runner VM compute when jobs are actually running.

### Useful Debugging Commands
```bash
# Check ARC controller health
kubectl get pods -n arc-systems
kubectl logs -n arc-systems deployment/arc-controller-gha-rs-controller

# Check listener status and job queue
kubectl logs -n arc-systems -l app.kubernetes.io/name=aks-runners -f

# Check runner scale set state
kubectl get autoscalingrunnersets -n arc-runners
kubectl get ephemeralrunnersets -n arc-runners
kubectl get ephemeralrunners -n arc-runners

# Watch runner pods in real time
kubectl get pods -n arc-runners -w

# Get runner pod logs
kubectl logs -n arc-runners <pod-name>

# Check events for errors
kubectl get events -n arc-runners --sort-by='.lastTimestamp'
kubectl get events -n arc-systems --sort-by='.lastTimestamp'

# Cancel stale GitHub Actions runs
gh run list --repo OWNER/REPO --limit 10
gh run cancel <RUN_ID> --repo OWNER/REPO

# Force-delete stuck EphemeralRunner
kubectl delete ephemeralrunner <NAME> -n arc-runners --force --grace-period=0
```

### File Reference

| File | Purpose |
|------|---------|
| `terraform/main.tf` | AKS cluster — public, kubenet, autoscaling |
| `terraform/variables.tf` | Cluster sizing and naming |
| `terraform/outputs.tf` | kubeconfig, cluster FQDN, get-credentials command |
| `terraform/workload-identity.tf` | User-assigned MI, Contributor role, federated credential |
| `helm/arc-controller-values.yaml` | ARC controller Helm values |
| `helm/arc-runner-set-values.yaml` | Runner scale set — min/max runners, image, command fix, `ARM_OIDC_TOKEN_FILE_PATH` |
| `k8s/workload-identity-sa.yaml` | Kubernetes service account with WI annotation |
| `k8s/runner-rbac.yaml` | RBAC for arc-runner service account |
| `scripts/deploy-runners.sh` | Full post-Terraform deployment script |
| `examples/storage-account/` | Sample Terraform — Azure Storage Account via OIDC |
| `examples/databricks-cluster/` | Sample Terraform — Databricks cluster via WI token exchange |
| `.github/workflows/deploy-storage.yml` | Workflow running Terraform on AKS runner with WI |
| `.github/workflows/deploy-databricks.yml` | Workflow deploying Databricks cluster via manual AAD token exchange |

---

## 6. Databricks Authentication Issues

> See full details with architecture diagrams and all failed approaches in [`examples/databricks-cluster/README.md`](examples/databricks-cluster/README.md).

### Issue 13: `azure_use_oidc` — unsupported argument in Databricks provider
**Symptom:** `Unsupported argument: An argument named "azure_use_oidc" is not expected here.`
**Fix:** Remove it. `azure_use_oidc` is an `azurerm` provider argument, not Databricks.

---

### Issue 14: Databricks provider v1.38 — no AKS Workload Identity support
**Symptom:** `cannot configure default credentials`
**Fix:** Upgrade provider to `~> 1.85`:
```hcl
databricks = {
  source  = "databricks/databricks"
  version = "~> 1.85"
}
```

---

### Issue 15: `azure_federated_token_file` / `azure_use_msi` — both fail for AKS WI pods

| Approach | Why it fails |
|----------|-------------|
| `azure_federated_token_file` | Targets GitHub OIDC audience, not AKS WI (`api://AzureADTokenExchange`) |
| `azure_use_msi = true` | Calls IMDS at `169.254.169.254` — returns **node** identity, not pod WI identity |

---

### Issue 16: `DATABRICKS_AAD_TOKEN` env var — not recognized by provider
**Symptom:** Token exchange succeeded but provider still failed auth.
**Cause:** The Databricks Go SDK reads `DATABRICKS_TOKEN`, not `DATABRICKS_AAD_TOKEN`.
**Fix:** Export the AAD token as `DATABRICKS_TOKEN`.

---

### Issue 17 (Resolved): Working solution — manual AAD token exchange

Add this step to the workflow **before** Terraform runs:

```yaml
- name: Exchange WI token for Databricks AAD token
  run: |
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
    if [ -z "$TOKEN" ]; then echo "Token exchange failed: $RESPONSE"; exit 1; fi
    echo "DATABRICKS_TOKEN=${TOKEN}" >> $GITHUB_ENV
```

Simplify the Databricks provider to:
```hcl
provider "databricks" {
  host = var.databricks_host
  # DATABRICKS_TOKEN read automatically from env
}
```

All required env vars (`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_FEDERATED_TOKEN_FILE`) are injected automatically by the AKS WI mutating webhook — no secrets needed.
