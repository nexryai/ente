provider "google" {
  project = var.project_id
  region  = var.region
}

# --- ネットワーク構成 ---
resource "google_compute_network" "vpc" {
  name                    = "ente-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet" {
  name          = "ente-subnet"
  ip_cidr_range = "10.0.1.0/24"
  network       = google_compute_network.vpc.id
  region        = var.region
}

resource "google_vpc_access_connector" "connector" {
  name          = "ente-run-conn"
  region        = var.region
  ip_cidr_range = "10.8.0.0/28"
  network       = google_compute_network.vpc.name
}

resource "google_artifact_registry_repository" "ghcr_proxy" {
  location      = var.region
  repository_id = "ghcr-proxy"
  format        = "DOCKER"
  mode          = "REMOTE_REPOSITORY"
  remote_repository_config {
    docker_repository {
      public_repository = "GITHUB_CONTAINER_REGISTRY"
    }
  }
}

# --- Secret Manager ---
resource "google_secret_manager_secret" "db_password" {
  secret_id = "ente-db-password"
  replication { auto {} }
}

resource "google_secret_manager_secret_version" "db_password_v" {
  secret      = google_secret_manager_secret.db_password.id
  secret_data = var.db_password
}

resource "google_secret_manager_secret" "museum_config" {
  secret_id = "museum-yaml-config"
  replication { auto {} }
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
      image = "cos-cloud/cos-stable"
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
    user-data = templatefile("${path.module}/cloud-init.yaml", {
      db_password = var.db_password
    })
  }

  service_account {
    email  = google_service_account.gce_sa.email
    scopes = ["cloud-platform"]
  }
}

resource "google_compute_firewall" "allow_postgres" {
  name    = "allow-postgres-from-run"
  network = google_compute_network.vpc.name
  allow {
    protocol = "tcp"
    ports    = ["5432"]
  }
  source_ranges = ["10.8.0.0/28"]
}

# --- Cloud Run (Museum) ---
resource "google_service_account" "run_sa" {
  account_id   = "ente-museum-sa"
  display_name = "Service Account for Museum Cloud Run"
}

resource "google_secret_manager_secret_iam_member" "run_secret_access" {
  secret_id = google_secret_manager_secret.museum_config.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.run_sa.email}"
}

resource "google_cloud_run_v2_service" "museum" {
  name     = "museum-server"
  location = var.region

  template {
    service_account = google_service_account.run_sa.email

    vpc_access {
      connector = google_vpc_access_connector.connector.id
      egress    = "ALL_TRAFFIC"
    }

    volumes {
      name = "config-vol"
      secret {
        secret = google_secret_manager_secret.museum_config.secret_id
        items {
          version = "latest"
          path    = "museum.yaml"
        }
      }
    }

    containers {
      image = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.ghcr_proxy.repository_id}/ente-io/server:latest"
      
      ports {
        container_port = 8080
      }

      volume_mounts {
        name       = "config-vol"
        mount_path = "/museum.yaml"
      }
    }
  }
}
