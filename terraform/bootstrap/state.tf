# El bucket ya existe (lo creamos con gcloud): Terraform lo adopta, no lo crea
import {
  to = google_storage_bucket.tfstate
  id = var.state_bucket
}

resource "google_storage_bucket" "tfstate" {
  name                        = var.state_bucket
  location                    = "US"
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true

  # Si el state se daña, se puede volver a una versión anterior
  versioning {
    enabled = true
  }

  # Aquí viven los states de todos los clientes: nunca se borra
  lifecycle {
    prevent_destroy = true
  }
}