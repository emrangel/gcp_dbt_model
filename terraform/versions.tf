terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
  }

  # Mismo bucket que el proyecto anterior, distinta carpeta
  backend "gcs" {
    bucket = "emra-co-tfstate"
    prefix = "trendy"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}