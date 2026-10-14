# ---------------------------------------------------------- Service accounts

resource "google_service_account" "runner" {
  account_id   = "${var.prefix}-runner"
  display_name = "${var.prefix}: ejecuta dbt en Cloud Run"
}

resource "google_service_account" "deployer" {
  account_id   = "${var.prefix}-deployer"
  display_name = "${var.prefix}: CI y despliegue desde GitHub"
}

resource "google_service_account" "scheduler" {
  account_id   = "${var.prefix}-scheduler"
  display_name = "${var.prefix}: dispara el job diario"
}

# ---------------------------------------------------------- Runner (prod)

resource "google_project_iam_member" "runner_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = google_service_account.runner.member
}

resource "google_bigquery_dataset_iam_member" "runner_prod_editor" {
  for_each   = { for k, v in local.datasets : k => v if v.env == "prod" }
  dataset_id = google_bigquery_dataset.dbt[each.key].dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = google_service_account.runner.member
}

# ---------------------------------------------------------- Deployer (ci)

resource "google_project_iam_member" "deployer_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = google_service_account.deployer.member
}

resource "google_bigquery_dataset_iam_member" "deployer_ci_editor" {
  for_each   = { for k, v in local.datasets : k => v if v.env == "ci" }
  dataset_id = google_bigquery_dataset.dbt[each.key].dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = google_service_account.deployer.member
}