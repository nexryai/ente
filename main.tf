provider "google" {
  project = var.project_id
  region  = var.region
}

terraform {
  backend "gcs" {
    bucket = "ente-terraform-state"
    prefix = "terraform/state"
  }
}

resource "google_service_account" "terraform_sa" {
  account_id   = "terraform-sa"
  display_name = "Terraform Execution Service Account"
}

resource "google_project_iam_member" "terraform_sa_admin" {
  project = var.project_id
  role    = "roles/editor"
  member  = "serviceAccount:${google_service_account.terraform_sa.email}"
}

# --- Workload Identity Federation (GitHub Actions 用) ---
resource "google_iam_workload_identity_pool" "github_pool" {
  workload_identity_pool_id = "github-pool"
  display_name              = "GitHub Actions Pool"
  description               = "Identity pool for GitHub Actions deployment"
}

resource "google_iam_workload_identity_pool_provider" "github_provider" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github_pool.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider"
  attribute_mapping = {
    "google.subject"             = "assertion.sub"
    "attribute.actor"            = "assertion.actor"
    "attribute.repository"       = "assertion.repository"
    "attribute.repository_owner" = "assertion.repository_owner"
  }
  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
  attribute_condition = "attribute.repository == '${var.github_repo}'"
}

resource "google_service_account_iam_member" "terraform_sa_workload_identity" {
  service_account_id = "projects/${var.project_id}/serviceAccounts/terraform-sa@${var.project_id}.iam.gserviceaccount.com"
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github_pool.name}/attribute.repository/${var.github_repo}"
}

# --- IAMポリシー ---
resource "google_service_account_iam_member" "sa_user_museum" {
  service_account_id = google_service_account.run_sa.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:terraform-sa@${var.project_id}.iam.gserviceaccount.com"
}

resource "google_service_account_iam_member" "sa_user_gce" {
  service_account_id = google_service_account.gce_sa.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:terraform-sa@${var.project_id}.iam.gserviceaccount.com"
}

resource "google_project_iam_member" "run_secret_accessor" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.run_sa.email}"
}

resource "google_project_iam_member" "gce_secret_accessor" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.gce_sa.email}"
}

# --- ネットワーク構成 ---
resource "google_compute_network" "vpc" {
  name                    = "ente-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet" {
  name                     = "ente-subnet"
  ip_cidr_range            = "10.0.1.0/24"
  network                  = google_compute_network.vpc.id
  region                   = var.region
  private_ip_google_access = true
}

# --- Artifact Registry ---
resource "google_artifact_registry_repository" "museum_repo" {
  location      = var.region
  repository_id = "museum-repo"
  format        = "DOCKER"

  cleanup_policies {
    id     = "keep-minimum-versions"
    action = "KEEP"
    most_recent_versions {
      keep_count = 2
    }
  }

  cleanup_policies {
    id     = "delete-unprotected-images"
    action = "DELETE"
    condition {
      older_than = "0s"
    }
  }
}

resource "google_artifact_registry_repository_iam_member" "pusher" {
  location   = google_artifact_registry_repository.museum_repo.location
  repository = google_artifact_registry_repository.museum_repo.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:terraform-sa@${var.project_id}.iam.gserviceaccount.com"
}

# --- Secret Manager ---
resource "google_secret_manager_secret" "db_password" {
  secret_id = "ente-db-password"
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
}

resource "google_secret_manager_secret_version" "db_password_v" {
  secret      = google_secret_manager_secret.db_password.id
  secret_data = var.db_password
}

resource "google_secret_manager_secret" "museum_config" {
  secret_id = "museum-yaml-config"
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
}

# 最新の COS Stable イメージ情報を取得
data "google_compute_image" "cos_latest" {
  family  = "cos-stable"
  project = "cos-cloud"
}

resource "terraform_data" "force_update" {
  input = timestamp()
}

# --- Compute Engine (PostgreSQL) ---
resource "google_service_account" "gce_sa" {
  account_id   = "ente-db-sa"
  display_name = "Service Account for Postgres GCE"
}

resource "google_compute_disk" "postgres_data" {
  name = "postgres-data-disk"
  type = "pd-standard"
  zone = var.zone
  size = 20
}

resource "google_compute_instance" "db_server" {
  name         = "ente-db-server"
  machine_type = "e2-micro"
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = data.google_compute_image.cos_latest.self_link
      size  = 10
    }
  }

  attached_disk {
    source      = google_compute_disk.postgres_data.id
    device_name = "postgres-data"
  }

  network_interface {
    network    = google_compute_network.vpc.id
    subnetwork = google_compute_subnetwork.subnet.id
    network_ip = "10.0.1.10"
  }

  metadata = {
    user-data = templatefile("${path.module}/cloud-init.yml", {
      db_password = var.db_password
    })
  }

  service_account {
    email  = google_service_account.gce_sa.email
    scopes = ["cloud-platform"]
  }

  # Apply のたびに強制的にインスタンスを再作成させる
  lifecycle {
    replace_triggered_by = [
      terraform_data.force_update
    ]
  }
}

resource "google_compute_firewall" "allow_postgres" {
  name    = "allow-postgres-from-run"
  network = google_compute_network.vpc.name
  allow {
    protocol = "tcp"
    ports    = ["5432"]
  }
  # Subnet 帯域からのみ許可
  source_ranges = [google_compute_subnetwork.subnet.ip_cidr_range]
}

resource "google_compute_firewall" "allow_ssh_iap" {
  name    = "allow-ssh-from-iap"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  # Google IAP が使用するIP
  source_ranges = ["35.235.240.0/20"]
}

# --- DBが起動するまでしばらく待機 ---
resource "time_sleep" "wait_3_minutes" {
  depends_on = [google_compute_instance.db_server]

  create_duration = "180s"
}

# --- Cloud Run (Museum) ---
resource "google_service_account" "run_sa" {
  account_id   = "ente-museum-sa"
  display_name = "Service Account for Museum Cloud Run"
}

resource "google_cloud_run_v2_service_iam_member" "noauth" {
  location   = google_cloud_run_v2_service.museum.location
  name       = google_cloud_run_v2_service.museum.name
  role       = "roles/run.invoker"
  member     = "allUsers"
  depends_on = [google_cloud_run_v2_service.museum]
}

resource "google_secret_manager_secret_iam_member" "run_secret_access" {
  secret_id = google_secret_manager_secret.museum_config.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.run_sa.email}"
}

resource "google_cloud_run_v2_service" "museum" {
  name     = "museum-server"
  deletion_protection = false
  location = var.region

  depends_on = [
    google_secret_manager_secret_iam_member.run_secret_access,
    time_sleep.wait_3_minutes
  ]

  template {
    service_account = google_service_account.run_sa.email

    scaling {
      max_instance_count = 1
    }

    vpc_access {
      egress = "PRIVATE_RANGES_ONLY"
      network_interfaces {
        network    = google_compute_network.vpc.id
        subnetwork = google_compute_subnetwork.subnet.id
      }
    }

    volumes {
      name = "config-vol"
      secret {
        secret = google_secret_manager_secret.museum_config.secret_id
        items {
          version = "latest"
          path    = "production.yaml"
        }
      }
    }

    containers {
      # image = "us-docker.pkg.dev/cloudrun/container/hello:latest"
      image = var.image_url

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        cpu_idle = true
      }

      ports {
        container_port = 8080
      }

      volume_mounts {
        name       = "config-vol"
        mount_path = "/var/config"
      }
    }
  }
}
