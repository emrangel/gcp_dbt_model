locals {
  # Vamos agregando APIs a medida que cada parte las necesite
  apis = [
    "bigquery.googleapis.com",
    "iam.googleapis.com"
  ]
}

resource "google_project_service" "apis" {
  for_each           = toset(local.apis)
  service            = each.value
  disable_on_destroy = false
}