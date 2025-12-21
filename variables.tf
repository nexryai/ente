variable "project_id" {
  type = string
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "region" {
  default = "us-west1"
}

variable "zone" {
  default = "us-west1-a"
}

variable "github_repo" {
  description = "GitHub Repository (username/reponame)"
  type        = string
}

variable "image_url" {
  description = "Container image URL for Cloud Run"
  type        = string
  default     = "us-docker.pkg.dev/cloudrun/container/hello"
}
