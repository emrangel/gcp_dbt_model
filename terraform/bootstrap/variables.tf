variable "project_id" {
  description = "Proyecto GCP compartido por todos los clientes."
  type        = string
  default     = "emra-co"
}

variable "state_bucket" {
  description = "Bucket donde viven los states de todos los clientes."
  type        = string
  default     = "emra-co-tfstate"
}