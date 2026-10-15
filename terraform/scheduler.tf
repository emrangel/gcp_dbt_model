resource "google_cloud_scheduler_job" "dbt_daily" {
  name             = "${var.prefix}-dbt-daily"
  region           = var.region
  schedule         = var.schedule
  time_zone        = var.time_zone
  attempt_deadline = "320s"

  retry_config {
    retry_count = 1
  }

  # Llama a la API de Cloud Run: "ejecuta este job"
  http_target {
    http_method = "POST"
    uri         = "https://run.googleapis.com/v2/projects/${var.project_id}/locations/${var.region}/jobs/${google_cloud_run_v2_job.dbt.name}:run"

    oauth_token {
      service_account_email = google_service_account.scheduler.email
    }
  }

  depends_on = [google_cloud_run_v2_job_iam_member.scheduler_invoker]
}