terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    flux = {
      source  = "fluxcd/flux"
      version = "~> 1.3"
    }
  }
}

# ── Variables ─────────────────────────────────────────────────────────────────
variable "project_id" { default = "eighth-physics-169321" }
variable "region" { default = "us-central1" }
variable "cluster_name" { default = "ortelius-gke" }

variable "github_org" { default = "ortelius" }
variable "github_repo" { default = "platform-iac" }
variable "github_token" {
  description = "GitHub PAT with repo scope (read/write for Flux GitOps pushes)"
  type        = string
  sensitive   = true
}

# ── Providers ─────────────────────────────────────────────────────────────────
provider "google" {
  project = var.project_id
  region  = var.region
}

# GCP access token is used by the flux kubernetes provider
data "google_client_config" "default" {}

provider "flux" {
  kubernetes = {
    host  = "https://${google_container_cluster.primary.endpoint}"
    token = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(
      google_container_cluster.primary.master_auth[0].cluster_ca_certificate
    )
  }
  git = {
    url = "https://github.com/${var.github_org}/${var.github_repo}.git"
    http = {
      username = "git"
      password = var.github_token
    }
  }
}

# ── VPC ───────────────────────────────────────────────────────────────────────
resource "google_compute_network" "vpc" {
  name                    = "${var.cluster_name}-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet" {
  name          = "${var.cluster_name}-subnet"
  region        = var.region
  network       = google_compute_network.vpc.id
  ip_cidr_range = "10.0.0.0/16"

  # Required for private nodes (no external IP) to reach Google APIs.
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.1.0.0/16"
  }
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.2.0.0/20"
  }
}

# ── GKE Cluster ───────────────────────────────────────────────────────────────
resource "google_container_cluster" "primary" {
  name     = var.cluster_name
  location = var.region

  network    = google_compute_network.vpc.name
  subnetwork = google_compute_subnetwork.subnet.name

  remove_default_node_pool = true
  initial_node_count       = 1

  depends_on = [google_compute_router_nat.nat]

  # Enable Dataplane V2
  datapath_provider = "ADVANCED_DATAPATH"

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Org policy constraints/compute.vmExternalIpAccess blocks node external IPs.
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.32/28"
  }
}

resource "google_compute_router" "router" {
  name    = "${var.cluster_name}-router"
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "${var.cluster_name}-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

resource "google_container_node_pool" "default" {
  name       = "default"
  location   = var.region
  cluster    = google_container_cluster.primary.name
  node_count = 2

  node_config {
    machine_type = "e2-standard-2"
    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }
}

# ── Flux Bootstrap ────────────────────────────────────────────────────────────
# Uses HTTPS + PAT (deploy keys disabled on Sol-Duara-Inc/pdvd-platform).
resource "flux_bootstrap_git" "gke" {
  # Flux will install its components into clusters/gke/flux-system/
  # and watch clusters/gke/ for workload kustomizations
  path = "clusters/gke"

  components_extra = ["image-reflector-controller", "image-automation-controller"]

  # Ensure the cluster nodes are up and the deploy key exists before bootstrapping
  depends_on = [
    google_container_node_pool.default,
    null_resource.sops_age_secret_pre_bootstrap # ENFORCES SECRET INJECTION BEFORE BOOTSTRAP
  ]
}

# ── Outputs ───────────────────────────────────────────────────────────────────
output "cluster_name" { value = google_container_cluster.primary.name }
output "cluster_endpoint" { value = google_container_cluster.primary.endpoint }