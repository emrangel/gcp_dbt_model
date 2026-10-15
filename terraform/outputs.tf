# Copia estos valores en GitHub → Settings → Secrets and variables → Actions → Variables
output "github_variables" {
  description = "Variables que usan los workflows de GitHub Actions."
  value = {
    GCP_PROJECT    = var.project_id
    GCP_REGION     = var.region
    WIF_PROVIDER   = google_iam_workload_identity_pool_provider.github.name
    DEPLOYER_SA    = google_service_account.deployer.email
    AR_REPO        = google_artifact_registry_repository.dbt.repository_id
    JOB_NAME       = google_cloud_run_v2_job.dbt.name
    DBT_CI_DATASET = "${var.prefix}_ci"
  }
}