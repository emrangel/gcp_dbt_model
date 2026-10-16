# gcp_dbt_model · dbt bronze → gold en GCP

Pipeline de datos de **Meta Ads** construido con **dbt** sobre **BigQuery**, que corre todos los días en **Cloud Run**, con la infraestructura en **Terraform** y CI/CD en **GitHub Actions**, sin ningún secreto guardado.

```
seeds/bronze_meta_ads.csv                  BRONZE  datos crudos, todo texto, con duplicados y errores
        │ ref()
models/silver/stg_meta_ads.sql             SILVER  tipado, normalizado y deduplicado      (vista)
        │ ref()
models/gold/fct_campaign_performance.sql   GOLD    una fila por campaña: CTR, CPC, CPM    (tabla)
```

> 📘 **¿Quieres construirlo desde cero?** La guía completa, etapa por etapa, con cada archivo explicado, está en [`docs/ROADMAP.md`](docs/ROADMAP.md).

---

## Cómo funciona

```
Tu máquina    uv run dbt build                                 ──► trendy_dev_*   (tu cuenta)

PR abierto    ci.yml ─ Workload Identity ─► dbt build --target ci  ──► trendy_ci_*    (trendy-deployer)
                    └─ terraform fmt + validate

Merge a main  deploy.yml ─ docker build ─► Artifact Registry ─► actualiza el Cloud Run Job

06:00 diario  Cloud Scheduler ──► Cloud Run Job ──► dbt build --target prod ──► trendy_*
              (trendy-scheduler)  (trendy-runner)
```

| Target | Quién lo usa | Datasets | Identidad |
|---|---|---|---|
| `dev` | Tú, en tu máquina | `trendy_dev_bronze/silver/gold` | Tu cuenta |
| `ci` | GitHub, en cada PR | `trendy_ci_bronze/silver/gold` | `trendy-deployer` |
| `prod` | Cloud Run, todos los días | `trendy_bronze/silver/gold` | `trendy-runner` |

**Seguridad**
- GitHub entra a GCP con **Workload Identity Federation**: tokens temporales, sin llaves JSON.
- Cada service account tiene **solo** los permisos que necesita: un PR no puede escribir en producción.
- Terraform corre **suplantando** a `trendy-terraform` (9 roles), no como owner.
- Cada cliente solo puede leer **su propio** state de Terraform.

---

## Estructura

```
.
├── .github/workflows/
│   ├── ci.yml                  En cada PR: dbt build --target ci + terraform fmt/validate
│   └── deploy.yml              En cada merge a main: build de la imagen y actualización del job
├── docs/ROADMAP.md             Guía paso a paso para reconstruir todo
├── models/
│   ├── silver/                 stg_meta_ads.sql + _silver.yml (tests)
│   └── gold/                   fct_campaign_performance.sql + _gold.yml (tests)
├── seeds/bronze_meta_ads.csv   Datos de ejemplo con errores a propósito
├── terraform/
│   ├── bootstrap/              Capa de plataforma: bucket del state y SA de Terraform por cliente
│   ├── versions.tf             Backend en GCS y provider, ambos suplantando a trendy-terraform
│   ├── variables.tf            Parámetros (prefix, región, horario, repo…)
│   ├── apis.tf                 APIs de GCP
│   ├── bigquery.tf             6 datasets (ci y prod × 3 capas)
│   ├── iam.tf                  Service accounts y permisos
│   ├── artifact_registry.tf    Repositorio de imágenes (conserva 10)
│   ├── cloud_run.tf            El job que ejecuta dbt
│   ├── scheduler.tf            Ejecución diaria
│   ├── workload_identity.tf    Acceso de GitHub sin llaves
│   ├── outputs.tf              Valores para las variables de GitHub
│   └── terraform.tfvars.example
├── Dockerfile                  python:3.12-slim + uv + dbt; ejecuta dbt build --target prod
├── dbt_project.yml             Proyecto dbt y configuración de capas
├── profiles.yml                Targets dev / ci / prod (sin secretos)
├── packages.yml                dbt_utils
├── package-lock.yml            Versión exacta de dbt_utils
├── pyproject.toml · uv.lock    Dependencias de Python
└── .python-version             3.12
```

---

## Desarrollo local

**Requisitos:** [uv](https://docs.astral.sh/uv/), [gcloud](https://cloud.google.com/sdk/docs/install) y acceso de lectura/escritura a BigQuery en el proyecto.

```powershell
gcloud auth application-default login
uv sync
uv run dbt deps
uv run dbt build
```

`profiles.yml` está en la raíz, así que no hace falta `DBT_PROFILES_DIR`. El proyecto por defecto es `emra-co`; para usar otro, define `GCP_PROJECT`:

```powershell
$env:GCP_PROJECT="mi-proyecto"
```

Resultado esperado: `Done. PASS=11 WARN=0 ERROR=0 SKIP=0 TOTAL=11` (1 seed + 2 modelos + 8 tests).

| Comando | Para qué |
|---|---|
| `uv run dbt build` | Seed + modelos + tests, en orden |
| `uv run dbt build --select stg_meta_ads` | Solo un modelo y sus tests |
| `uv run dbt show --select fct_campaign_performance` | Ver datos sin crear nada |
| `uv run dbt compile` | Ver el SQL generado en `target/compiled/` |
| `uv run dbt docs generate` + `uv run dbt docs serve` | Documentación y linaje en `localhost:8080` |
| `uv run dbt clean` | Borrar `target/` y `dbt_packages/` |

> Detrás de un proxy corporativo, si uv falla con `invalid peer certificate: UnknownIssuer`: `setx UV_SYSTEM_CERTS 1`.

---

## Replicarlo en tu cuenta

El resumen está aquí; el detalle de cada paso, en [`docs/ROADMAP.md`](docs/ROADMAP.md).

### 1 · Requisitos

- Proyecto de GCP con **facturación activa** donde seas **owner**.
- Cuenta de GitHub con una **llave SSH** configurada.
- `gcloud`, Terraform ≥ 1.6, uv, git. Docker **no** hace falta.

### 2 · Reemplaza los valores de este repo

| Valor | Qué es | Archivos |
|---|---|---|
| `emra-co` | Proyecto de GCP | `profiles.yml`, `terraform/versions.tf`, `terraform/bootstrap/variables.tf`, `terraform.tfvars` |
| `emra-co-tfstate` | Bucket del state (nombre único en todo GCP) | `terraform/versions.tf`, `terraform/bootstrap/versions.tf`, `terraform/bootstrap/variables.tf` |
| `trendy` | Prefijo del cliente | `dbt_project.yml`, `profiles.yml`, `terraform/versions.tf`, `terraform/bootstrap/variables.tf`, `terraform.tfvars` |
| `erriick1122@gmail.com` | Admin que suplanta la SA de Terraform | `terraform/bootstrap/variables.tf` |
| `emrangel/gcp_dbt_model` | Repo que puede desplegar | `terraform.tfvars` |

Si el bucket **no existe**, borra el bloque `import` de `terraform/bootstrap/state.tf`: así Terraform lo crea en lugar de adoptarlo.

### 3 · Bootstrap (una vez, como owner)

```powershell
gcloud services enable cloudresourcemanager.googleapis.com iam.googleapis.com iamcredentials.googleapis.com --project <proyecto>
cd terraform\bootstrap
```

Comenta el bloque `backend "gcs"` de `bootstrap/versions.tf` (el bucket todavía no existe), y luego:

```powershell
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

Descomenta el `backend` y mueve el state al bucket:

```powershell
terraform init -migrate-state
del terraform.tfstate
del terraform.tfstate.backup
cd ..
```

### 4 · Infraestructura del cliente (como `<prefijo>-terraform`)

Espera unos minutos a que se propaguen los permisos del bootstrap, y luego:

```powershell
copy terraform.tfvars.example terraform.tfvars    # edita tus valores
terraform init
terraform plan -out=tfplan                        # 34 to add
terraform apply tfplan
terraform output github_variables
cd ..
```

### 5 · GitHub

1. Crea el repo con **exactamente** el nombre de `github_repo` y súbelo.
2. **Settings → Secrets and variables → Actions → pestaña Variables** (no Secrets): crea las 7 de `terraform output github_variables`.
3. Opcional: **Settings → Environments → `production`** con *Required reviewers*.

| Variable | Ejemplo |
|---|---|
| `GCP_PROJECT` | `emra-co` |
| `GCP_REGION` | `us-central1` |
| `WIF_PROVIDER` | `projects/<número>/locations/global/workloadIdentityPools/trendy-github/providers/github` |
| `DEPLOYER_SA` | `trendy-deployer@emra-co.iam.gserviceaccount.com` |
| `AR_REPO` | `trendy` |
| `JOB_NAME` | `trendy-dbt` |
| `DBT_CI_DATASET` | `trendy_ci` |

### 6 · Primer deploy

**Actions → deploy → Run workflow → marca `run_now`.** Verifica en Cloud Run → Jobs → `trendy-dbt` → Executions: los logs deben terminar en `PASS=11`.

---

## Flujo de trabajo

| Quieres… | Haces… |
|---|---|
| Cambiar SQL | Rama → editas → `uv run dbt build` → PR → `ci` en verde → merge → `deploy` |
| Cambiar infraestructura | Editas `terraform/` → `terraform fmt` → `plan -out=tfplan` → revisas → `apply tfplan` → PR |
| Ejecutar fuera de horario | `gcloud run jobs execute trendy-dbt --region us-central1 --project emra-co --wait` |
| Ejecutar solo un modelo | `gcloud run jobs execute trendy-dbt --region us-central1 --project emra-co --args="build,--select,fct_campaign_performance,--target,prod"` |
| Ver qué pasó en prod | Cloud Run → Jobs → `trendy-dbt` → Executions |

- Un PR que solo cambia `terraform/` o archivos `.md` **no** dispara deploy.
- El deploy automático del merge **no** ejecuta el job: corre a las 6:00 (`America/Bogota`), o a mano con `run_now`.
- Terraform ignora la imagen del job (`ignore_changes`): la cambia el pipeline de deploy.

---

## Problemas frecuentes

| Mensaje | Solución |
|---|---|
| `no such host` / `NameResolutionError` | Fallo de DNS de la red: reintentar |
| `must specify exactly one of "workload_identity_provider"` | Las variables están en Secrets o en el environment: muévelas a Repository variables |
| `Path '...\.dbt' does not exist` | Ejecuta dbt desde la raíz del repo, donde está `profiles.yml` |
| `uv` no se reconoce después de instalarlo | Cierra VS Code por completo y ábrelo de nuevo |
| Terraform: *already exists* | Prefijo repetido en el proyecto, o corriste `dbt build --target prod` en local |
| El deploy terminó y no hay ejecución | Faltó marcar `run_now` |

Más casos y explicaciones en [`docs/ROADMAP.md`](docs/ROADMAP.md#errores-comunes).

---

**Versiones:** dbt-core 1.12.5 · dbt-bigquery 1.12.1 · dbt_utils 1.4.1 · uv 0.13.0 · Python 3.12 · Terraform ≥ 1.6 · proveedor google 7.x
