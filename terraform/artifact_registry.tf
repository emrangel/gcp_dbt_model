# Aquí GitHub sube las imágenes Docker de dbt
resource "google_artifact_registry_repository" "dbt" {
  repository_id = var.prefix
  location      = var.region
  format        = "DOCKER"
  description   = "Imágenes del job de dbt de ${var.prefix}"

  # Cada deploy sube una imagen nueva: conservamos solo las 10 más recientes
  cleanup_policies {
    id     = "keep-last-10"
    action = "KEEP"
    most_recent_versions {
      keep_count = 10
    }
  }

  depends_on = [google_project_service.apis]
}

# El deployer (GitHub) puede subir imágenes, solo a ESTE repositorio
resource "google_artifact_registry_repository_iam_member" "deployer_writer" {
  location   = google_artifact_registry_repository.dbt.location
  repository = google_artifact_registry_repository.dbt.name
  role       = "roles/artifactregistry.writer"
  member     = google_service_account.deployer.member
}