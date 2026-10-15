resource "google_cloud_run_v2_job" "dbt" {
  name                = "${var.prefix}-dbt"
  location            = var.region
  deletion_protection = false

  template {
    task_count = 1

    template {
      service_account = google_service_account.runner.email
      timeout         = "1800s"
      max_retries     = 1

      containers {
        # Imagen de prueba de Google. GitHub la reemplaza en cada deploy.
        image = "us-docker.pkg.dev/cloudrun/container/job:latest"

        # profiles.yml (target prod) lee estas variables
        env {
          name  = "GCP_PROJECT"
          value = var.project_id
        }
        env {
          name  = "DBT_DATASET"
          value = var.prefix
        }

        resources {
          limits = {
            cpu    = "1"
            memory = "1Gi"
          }
        }
      }
    }
  }

  # La imagen la maneja el pipeline de deploy, no Terraform
  lifecycle {
    ignore_changes = [
      template[0].template[0].containers[0].image,
      client,
      client_version,
    ]
  }

  depends_on = [google_project_service.apis]
}

# Scheduler puede ejecutar ESTE job
resource "google_cloud_run_v2_job_iam_member" "scheduler_invoker" {
  location = google_cloud_run_v2_job.dbt.location
  name     = google_cloud_run_v2_job.dbt.name
  role     = "roles/run.invoker"
  member   = google_service_account.scheduler.member
}

# El deployer (GitHub) puede actualizar la imagen de ESTE job
resource "google_cloud_run_v2_job_iam_member" "deployer_developer" {
  location = google_cloud_run_v2_job.dbt.location
  name     = google_cloud_run_v2_job.dbt.name
  role     = "roles/run.developer"
  member   = google_service_account.deployer.member
}