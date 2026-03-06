# AKS GitHub Self-Hosted Runners

Provisions an AKS cluster on Azure with GitHub Actions self-hosted runners using the official [Actions Runner Controller (ARC) v2](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners-with-actions-runner-controller/quickstart-for-actions-runner-controller).

## Architecture

```
GitHub Actions Workflow (runs-on: aks-runners)
       |
       v
GitHub API  <---->  ARC Controller Pod (arc-systems namespace)
                         |
                         v (scales on job queue)
                    Runner Pods (arc-runners namespace)
                    - spin up when jobs are queued
                    - terminate after job completes
```

## Prerequisites

| Tool | Version |
|------|---------|
| [Terraform](https://developer.hashicorp.com/terraform/install) | >= 1.5 |
| [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) | latest |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | latest |
| [Helm](https://helm.sh/docs/intro/install/) | >= 3.x |

Azure CLI must be logged in: `az login`

## Step 1: Provision AKS Cluster

```bash
cd terraform

# Copy and optionally edit variables
cp terraform.tfvars.example terraform.tfvars

terraform init
terraform apply
```

Configure kubectl after apply:
```bash
$(terraform output -raw get_credentials_command)
```

## Step 2: Deploy GitHub Runners

You need a GitHub PAT with `repo` scope to register repository-level runners.

Create one at: GitHub → Settings → Developer Settings → Personal Access Tokens → Fine-grained tokens
Required permissions: **Actions** (Read & Write), **Administration** (Read & Write)

```bash
export GITHUB_PAT=ghp_xxxxxxxxxxxxxxxxxxxx
export GITHUB_OWNER=your-org-or-username
export GITHUB_REPO=your-repo-name

./scripts/deploy-runners.sh
```

## Step 3: Use in GitHub Actions

```yaml
jobs:
  build:
    runs-on: aks-runners    # matches runnerScaleSetName in arc-runner-set-values.yaml
    steps:
      - uses: actions/checkout@v4
      - run: echo "Running on AKS!"
```

Runners appear at:
`https://github.com/OWNER/REPO/settings/actions/runners`

## Verify Deployment

```bash
# ARC controller (should show 1 running pod)
kubectl get pods -n arc-systems

# Runner listener (1 listener pod; runner pods appear when jobs run)
kubectl get pods -n arc-runners

# View ARC controller logs
kubectl logs -n arc-systems -l app.kubernetes.io/name=gha-runner-scale-set-controller -f

# View runner scale set status
kubectl get autoscalingrunnersets -n arc-runners
```

## Teardown

```bash
# Remove runners
helm uninstall aks-runners -n arc-runners
helm uninstall arc-controller -n arc-systems

# Destroy AKS cluster
cd terraform && terraform destroy
```

## Configuration

| File | Purpose |
|------|---------|
| `terraform/main.tf` | AKS cluster (public, kubenet, autoscaling nodes) |
| `terraform/variables.tf` | Cluster sizing and naming |
| `helm/arc-controller-values.yaml` | ARC controller Helm values |
| `helm/arc-runner-set-values.yaml` | Runner scale set (min/max runners, resources) |

### Customising Runner Resources

Edit `helm/arc-runner-set-values.yaml`:
```yaml
maxRunners: 10          # increase for more parallel jobs
template:
  spec:
    containers:
      - name: runner
        resources:
          limits:
            cpu: "4"
            memory: "8Gi"
```

Then re-run the Helm upgrade:
```bash
helm upgrade aks-runners \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  --version 0.9.3 \
  --namespace arc-runners \
  --values helm/arc-runner-set-values.yaml \
  --set githubConfigUrl="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}"
```
