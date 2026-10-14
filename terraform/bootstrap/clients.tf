locals {
  # Lo mínimo para que un cliente aplique su propio Terraform
  terraform_roles = [
    "roles/serviceusage.serviceUsageAdmin",  # activar APIs
    "roles/bigquery.admin",                  # datasets y sus permisos
    "roles/iam.serviceAccountAdmin",         # crear SAs y sus permisos
    "roles/resourcemanager.projectIamAdmin", # permisos a nivel de proyecto
    "roles/iam.serviceAccountUser",          # configurar recursos que corren como otra SA
    "roles/artifactregistry.admin",          # repositorio de imágenes
    "roles/run.admin",                       # Cloud Run Job
    "roles/cloudscheduler.admin",            # Scheduler
    "roles/iam.workloadIdentityPoolAdmin",   # acceso desde GitHub
  ]

  # Todas las combinaciones cliente × rol
  client_roles = {
    for pair in setproduct(var.clients, local.terraform_roles) :
    "${pair[0]}|${pair[1]}" => {
      client = pair[0]
      role   = pair[1]
    }
  }
}

# ------------------------------------------------------- La SA de cada cliente

resource "google_service_account" "terraform" {
  for_each     = toset(var.clients)
  account_id   = "${each.key}-terraform"
  display_name = "${each.key}: aplica Terraform"
}

# ------------------------------------------------------- Sus roles en el proyecto

resource "google_project_iam_member" "terraform" {
  for_each = local.client_roles
  project  = var.project_id
  role     = each.value.role
  member   = google_service_account.terraform[each.value.client].member
}

# ------------------------------------------------------- Solo SU carpeta del state

resource "google_storage_bucket_iam_member" "terraform_state" {
  for_each = toset(var.clients)
  bucket   = google_storage_bucket.tfstate.name
  role     = "roles/storage.objectAdmin"
  member   = google_service_account.terraform[each.key].member

  condition {
    title       = "solo-state-${each.key}"
    description = "Solo puede leer y escribir objetos bajo ${each.key}/"
    expression  = "resource.name.startsWith(\"projects/_/buckets/${var.state_bucket}/objects/${each.key}/\") || resource.name == \"projects/_/buckets/${var.state_bucket}\""
  }
}

# ------------------------------------------------------- El admin puede suplantarla

resource "google_service_account_iam_member" "admin_impersonates" {
  for_each           = toset(var.clients)
  service_account_id = google_service_account.terraform[each.key].name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = var.admin
}