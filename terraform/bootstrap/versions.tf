terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
  }

  # El state de bootstrap vive en el mismo bucket que administra.
  # Lo aplica el admin con su propia cuenta (sin suplantar).
  backend "gcs" {
    bucket = "emra-co-tfstate"
    prefix = "bootstrap"
  }
}

# Sin este bloque, Terraform tomaría el proyecto de la configuración local de gcloud
provider "google" {
  project = var.project_id
}