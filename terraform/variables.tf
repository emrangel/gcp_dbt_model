variable "project_id" {
  description = "Proyecto GCP donde vive todo."
  type        = string
}

variable "region" {
  description = "Región de Cloud Run, Scheduler y Artifact Registry."
  type        = string
  default     = "us-central1"
}

variable "bq_location" {
  description = "Ubicación de los datasets de BigQuery."
  type        = string
  default     = "US"
}

variable "prefix" {
  description = "Nombre corto del cliente. Todos los recursos llevan este prefijo."
  type        = string
}

variable "schedule" {
  description = "Cron de la ejecución diaria."
  type        = string
  default     = "0 6 * * *"
}

variable "time_zone" {
  description = "Zona horaria del cron."
  type        = string
  default     = "America/Bogota"
}