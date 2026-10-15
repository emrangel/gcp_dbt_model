terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
  }

  # El state lo lee y escribe trendy-terraform, no tu cuenta
  backend "gcs" {
    bucket                      = "emra-co-tfstate"
    prefix                      = "trendy"
    impersonate_service_account = "trendy-terraform@emra-co.iam.gserviceaccount.com"
  }
}

# Los recursos los crea trendy-terraform, no tu cuenta
provider "google" {
  project                     = var.project_id
  region                      = var.region
  impersonate_service_account = "${var.prefix}-terraform@${var.project_id}.iam.gserviceaccount.com"
}