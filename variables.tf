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
