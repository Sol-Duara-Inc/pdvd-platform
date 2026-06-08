# Deploy Ortelius on GKE (Sol Duara POC)

Target URL: **https://ortelius.dev.solduara.com**  
GCP project: `cs-poc-byzydokth1uym6142bdtqml`  
Cluster: `ortelius-poc-gke`  
GitOps repo: `Sol-Duara-Inc/pdvd-platform`

**Recommended control host:** **jb-bastion** (Ubuntu). Terraform talks to GCP APIs from the bastion; workloads run in GKE (not on the bastion).

---

## Phase 0 — Prerequisites on jb-bastion (Ubuntu)

SSH to the bastion, then install tools once.

### Base packages

```bash
sudo apt-get update
sudo apt-get install -y curl gnupg ca-certificates apt-transport-https \
  git jq dnsutils openssh-client
```

### Google Cloud SDK + GKE auth plugin

```bash
curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg

echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
  | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list

sudo apt-get update
sudo apt-get install -y google-cloud-cli google-cloud-cli-gke-gcloud-auth-plugin
```

### Terraform (HashiCorp apt repo)

```bash
curl -fsSL https://apt.releases.hashicorp.com/gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
  https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list

sudo apt-get update
sudo apt-get install -y terraform
```

### kubectl

```bash
sudo apt-get install -y kubectl
# Or: gcloud components install kubectl
```

### Helm 3

```bash
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

### Flux CLI (optional)

Terraform bootstraps Flux via the provider; the CLI is only needed for troubleshooting.

```bash
curl -s https://fluxcd.io/install.sh | sudo bash
```

`deploy.sh` installs **age** and **sops** automatically if missing (may use `sudo` on the bastion).

### GCP credentials

**Interactive (user account):**

```bash
gcloud auth login --no-launch-browser
gcloud auth application-default login --no-launch-browser
gcloud config set project cs-poc-byzydokth1uym6142bdtqml
```

**Service account (headless / CI-style):**

```bash
# Copy key to bastion, e.g. /home/<user>/.config/gcp/ortelius-poc-sa.json
export GOOGLE_APPLICATION_CREDENTIALS="$HOME/.config/gcp/ortelius-poc-sa.json"
gcloud config set project cs-poc-byzydokth1uym6142bdtqml
```

### GitHub

```bash
export TF_VAR_github_token="ghp_..."   # PAT: repo + admin:public_key
```

Clone the repo (SSH or HTTPS):

```bash
git clone git@github.com:Sol-Duara-Inc/pdvd-platform.git
cd pdvd-platform
```

Ensure `git@github.com` works from the bastion (`ssh -T git@github.com`) — Flux bootstrap registers a deploy key on the repo.

### GitHub OAuth App

Create or update in GitHub → Developer settings:

- Homepage: `https://ortelius.dev.solduara.com`
- Callback: per your OAuth app / Ortelius docs

Have ready: ArangoDB password, SMTP (or POC dummy), GitHub App ID/secret/private key, PAT for `Sol-Duara-Inc/pdvd-rbac` (write).

### Verify tools

```bash
terraform version
kubectl version --client
helm version
gcloud config get-value project
test -n "${TF_VAR_github_token:-}" && echo "TF_VAR_github_token: set" || echo "TF_VAR_github_token: NOT set"
```

---

## Phase 1 — Secrets (age + SOPS)

If you **do not** have `~/.ssh/ortelius-poc-gke.sops.key` matching `.sops.yaml`, regenerate on the **same host** that will run `apply`:

```bash
cd ~/pdvd-platform   # or your clone path
rm -f clusters/gke/ortelius/secrets.enc.yaml
```

On first `gke apply`, `deploy.sh` prompts for secrets. Use:

| Prompt | Value |
|--------|--------|
| `prtelius.baseUrl` | `https://ortelius.dev.solduara.com` |
| `ortelius.rbac_repo_token` | PAT with `repo` scope and **push** access to `Sol-Duara-Inc/pdvd-rbac` |

Back up the age key from the bastion (copy to secure storage):

```bash
ls -la ~/.ssh/ortelius-poc-gke.sops.key
chmod 600 ~/.ssh/ortelius-poc-gke.sops.key
```

### Existing cluster — rotate RBAC repo token

If `secrets.enc.yaml` already exists, update only `ortelius.rbac_repo_token` (PAT with **push** to `Sol-Duara-Inc/pdvd-rbac`) on the bastion that holds `~/.ssh/ortelius-poc-gke.sops.key`:

```bash
cd ~/pdvd-platform
sops clusters/gke/ortelius/secrets.enc.yaml   # edit ortelius.rbac_repo_token in values.yaml JSON
git add clusters/gke/ortelius/secrets.enc.yaml
git commit -m "fix: rbac token for Sol-Duara-Inc/pdvd-rbac"
git push origin main
kubectl rollout restart deployment -n ortelius -l app=ortelius
```

---

## Phase 2 — Push GitOps config

Commit from bastion (or Mac), then push so Flux sees the latest manifests:

```bash
cd ~/pdvd-platform
git pull origin main
git status
git add -A
git commit -m "feat: gke ingress for ortelius.dev.solduara.com"
git push origin main
```

---

## Phase 3 — Deploy infrastructure

Run from the repo root on the bastion:

```bash
cd ~/pdvd-platform
./terraform/deploy.sh gke plan    # review (~30–45 min apply)
./terraform/deploy.sh gke apply
```

Terraform creates: VPC, GKE cluster, global IP `ortelius-gke-ip`, Cloud DNS **A** in zone `dev`, Flux bootstrap, `clusters/gke/ortelius/values.yaml`.

No separate GCP Console setup for `/api/v1` — only the hostname; API paths are Ingress rules inside the cluster.

---

## Phase 4 — Verify

```bash
gcloud container clusters get-credentials ortelius-poc-gke \
  --region us-central1 \
  --project cs-poc-byzydokth1uym6142bdtqml

kubectl get pods -n flux-system
kubectl get pods -n ortelius
kubectl get helmrelease -n flux-system
kubectl get ingress,managedcertificate -n ortelius

terraform -chdir=terraform/gke output ortelius_url static_ip dns_record
dig +short ortelius.dev.solduara.com
```

ManagedCertificate may take **15–60 minutes** after DNS propagates.

---

## Phase 5 — Open UI

https://ortelius.dev.solduara.com

---

## Tear down

```bash
cd ~/pdvd-platform
./terraform/deploy.sh gke destroy
```

---

## Optional: macOS (local laptop)

Same phases; different package installs:

```bash
brew install terraform kubectl helm
brew install hashicorp/tap/terraform   # if needed
brew install fluxcd/tap/flux           # optional

gcloud auth application-default login
gcloud config set project cs-poc-byzydokth1uym6142bdtqml
export TF_VAR_github_token="ghp_..."
```

Use **either** bastion **or** Mac for `plan`/`apply`, not both with different age keys on the same `secrets.enc.yaml`. If you switch hosts, copy `~/.ssh/ortelius-poc-gke.sops.key` or regenerate secrets on the new host.

---

## Bastion checklist

| Item | Bastion |
|------|---------|
| OS | Ubuntu (jb-bastion) |
| Runs Terraform? | Yes — against GCP APIs |
| Runs inside GKE? | No |
| Needs `kubectl`? | Yes — for verify (after cluster exists) |
| DNS for `/api/v1` in Console? | No — hostname A record only |
| `TF_VAR_github_token` | Export in shell profile or before `deploy.sh` |
