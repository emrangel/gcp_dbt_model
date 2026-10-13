locals {
  # prod escribe en trendy_*, ci en trendy_ci_*
  envs = {
    prod = var.prefix
    ci   = "${var.prefix}_ci"
  }

  layers = ["bronze", "silver", "gold"]

  # Todas las combinaciones entorno × capa
  datasets = {
    for pair in setproduct(keys(local.envs), local.layers) :
    "${pair[0]}_${pair[1]}" => {
      env        = pair[0]
      dataset_id = "${local.envs[pair[0]]}_${pair[1]}"
    }
  }
}

resource "google_bigquery_dataset" "dbt" {
  for_each   = local.datasets
  dataset_id = each.value.dataset_id
  location   = var.bq_location

  labels = {
    managed_by = "terraform"
    client     = var.prefix
    env        = each.value.env
  }

  # Los de CI se pueden borrar con contenido; los de prod no
  delete_contents_on_destroy = each.value.env == "ci"

  depends_on = [google_project_service.apis]
}