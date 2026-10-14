# APIs que necesita la plataforma antes de que cualquier cliente aplique nada
resource "google_project_service" "platform" {
  for_each = toset([
    "cloudresourcemanager.googleapis.com", # leer/escribir permisos del proyecto
    "iamcredentials.googleapis.com",       # generar tokens al suplantar una SA
  ])
  service            = each.value
  disable_on_destroy = false
}