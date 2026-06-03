# terraform/gke/terraform.tfvars
# github_token: export TF_VAR_github_token="ghp_..."

project_id         = "cs-poc-byzydokth1uym6142bdtqml"
region             = "us-central1"
cluster_name       = "ortelius-poc-gke"
domain             = "ortelius.junctionbox.dev.solduara.com"
dns_managed_zone   = "dev"
static_ip_name     = "ortelius-gke-ip"

github_org  = "Sol-Duara-Inc"
github_repo = "pdvd-platform"
