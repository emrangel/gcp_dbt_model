# El "edificio": identidades externas que GCP acepta
resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "${var.prefix}-github"
  display_name              = "${var.prefix}: GitHub"

  depends_on = [google_project_service.apis]
}

# La "recepción": confía en GitHub, pero solo en tu repo
resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  display_name                       = "GitHub Actions"

  # Qué datos del token de GitHub conservamos, y con qué nombre
  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }

  # Cualquier otro repo de GitHub es rechazado aquí mismo
  attribute_condition = "assertion.repository == \"${var.github_repo}\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# La "llave del piso": quien pase la recepción puede actuar como trendy-deployer
resource "google_service_account_iam_member" "deployer_wif" {
  service_account_id = google_service_account.deployer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repo}"
}