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


variable "clients" {
  description = "Clientes con su propio Terraform. Cada uno recibe <cliente>-terraform."
  type        = list(string)
  default     = ["trendy"]
}

variable "admin" {
  description = "Quién puede suplantar las SA de Terraform (formato user:correo)."
  type        = string
  default     = "user:erriick1122@gmail.com"
}