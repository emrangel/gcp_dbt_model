terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
  }

  # Sin bloque "backend": el state queda local (terraform.tfstate).
  # En B3 lo movemos al bucket.
}

provider "google" {
  project = var.project_id
}