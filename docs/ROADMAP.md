# Roadmap: dbt bronze → gold en GCP, paso a paso

Esta guía reconstruye este repositorio **desde una carpeta vacía**. Es el mismo camino que seguimos al crearlo: cada etapa explica qué se construye, por qué, el contenido completo de cada archivo, los comandos y cómo comprobar que funcionó antes de seguir.

Al terminar tendrás:

- Un pipeline **dbt** sobre **BigQuery** con tres capas: bronze (crudo), silver (limpio) y gold (KPIs), con tests.
- Una imagen **Docker** que corre en **Cloud Run** y se dispara todos los días con **Cloud Scheduler**.
- Toda la infraestructura en **Terraform**, aplicada con una service account de mínimo privilegio, no como owner.
- **CI/CD en GitHub Actions**: cada PR prueba dbt y Terraform; cada merge despliega.
- **Cero secretos**: GitHub entra a GCP con Workload Identity Federation, sin llaves JSON.

---

## Índice

- [Cómo usar esta guía](#cómo-usar-esta-guía)
- [Parte I · Conceptos y arquitectura](#parte-i--conceptos-y-arquitectura)
- [Parte II · Preparación](#parte-ii--preparación)
  - [Etapa 0 · Cuentas y herramientas](#etapa-0--cuentas-y-herramientas)
- [Parte III · dbt en tu máquina](#parte-iii--dbt-en-tu-máquina)
  - [Etapa 1 · Base del proyecto](#etapa-1--base-del-proyecto)
  - [Etapa 2 · dbt conectado a BigQuery](#etapa-2--dbt-conectado-a-bigquery)
  - [Etapa 3 · Bronze: los datos crudos](#etapa-3--bronze-los-datos-crudos)
  - [Etapa 4 · Silver: limpiar y probar](#etapa-4--silver-limpiar-y-probar)
  - [Etapa 5 · Gold: KPIs para el negocio](#etapa-5--gold-kpis-para-el-negocio)
  - [Etapa 6 · Docker](#etapa-6--docker)
- [Parte IV · Infraestructura con Terraform](#parte-iv--infraestructura-con-terraform)
  - [Etapa 7.0 · Bootstrap de plataforma](#etapa-70--bootstrap-de-plataforma)
  - [Etapa 7A · Configuración base y datasets](#etapa-7a--configuración-base-y-datasets)
  - [Etapa 7B · Service accounts y permisos](#etapa-7b--service-accounts-y-permisos)
  - [Etapa 7C · Dónde y cuándo corre dbt](#etapa-7c--dónde-y-cuándo-corre-dbt)
  - [Etapa 7D · GitHub sin llaves](#etapa-7d--github-sin-llaves)
- [Parte V · GitHub y despliegue](#parte-v--github-y-despliegue)
  - [Etapa 8 · CI/CD](#etapa-8--cicd)
  - [Etapa 9 · Primer deploy](#etapa-9--primer-deploy)
- [Parte VI · Operación diaria](#parte-vi--operación-diaria)
- [Parte VII · Referencia](#parte-vii--referencia)
  - [Errores comunes](#errores-comunes)
  - [Preguntas que surgieron](#preguntas-que-surgieron)
  - [Pendientes](#pendientes)

---

## Cómo usar esta guía

**Reglas de trabajo**

1. **Una etapa a la vez.** Cada una termina con un **✅ Checkpoint**. No pases a la siguiente hasta que se cumpla.
2. **Escribe los archivos tú.** Copiar y pegar funciona, pero escribirlos a mano es como se aprende la sintaxis.
3. **Commit al final de cada etapa.** Si luego rompes algo, puedes volver a ese punto.
4. **Lee los errores antes de arreglarlos.** La sección [Errores comunes](#errores-comunes) explica cómo distinguir un error de red de uno de código.

**Terminal**

Los comandos son para **PowerShell** en Windows. Si tu prompt no empieza con `PS`, estás en CMD y la sintaxis cambia:

| Qué hace | PowerShell | CMD |
|---|---|---|
| Definir una variable | `$env:GCP_PROJECT="emra-co"` | `set GCP_PROJECT=emra-co` |
| Leer una variable | `echo $env:GCP_PROJECT` | `echo %GCP_PROJECT%` |
| Encadenar comandos | `cmd1; cmd2` | `cmd1 && cmd2` |

En macOS o Linux los comandos son los mismos, salvo `copy` → `cp`, `del` → `rm`, `mkdir a\b` → `mkdir -p a/b` y las variables (`export VAR=valor`).

**Valores de este repo y qué reemplazar**

Todos los archivos usan los valores reales con los que se construyó el repo. Para replicarlo en tu cuenta, reemplázalos:

| Valor en el repo | Qué es | Dónde aparece |
|---|---|---|
| `emra-co` | Proyecto de GCP | `profiles.yml`, `terraform/versions.tf`, `terraform/bootstrap/variables.tf`, `terraform.tfvars` |
| `emra-co-tfstate` | Bucket del state de Terraform (nombre único en todo GCP) | `terraform/versions.tf`, `terraform/bootstrap/versions.tf`, `terraform/bootstrap/variables.tf` |
| `trendy` | Prefijo del cliente: lo llevan todos los recursos | `dbt_project.yml`, `profiles.yml`, `terraform/versions.tf`, `terraform/bootstrap/variables.tf`, `terraform.tfvars` |
| `erriick1122@gmail.com` | Tu cuenta de Google | `terraform/bootstrap/variables.tf` |
| `emrangel/gcp_dbt_model` | Tu repo de GitHub (`owner/repo`) | `terraform.tfvars` |
| `github-personal` | Alias SSH para tu cuenta de GitHub | URL del remoto de git |
| `1052961859131` | Número del proyecto de GCP (lo calcula Terraform) | Variable `WIF_PROVIDER` en GitHub |

---

## Parte I · Conceptos y arquitectura

### Las tres capas

```
seeds/bronze_meta_ads.csv                  BRONZE  datos crudos, todo como texto, con duplicados y errores
        │ ref()
models/silver/stg_meta_ads.sql             SILVER  tipado, normalizado y deduplicado            (vista)
        │ ref()
models/gold/fct_campaign_performance.sql   GOLD    una fila por campaña con CTR, CPC y CPM      (tabla)
```

| Capa | Trabajo | Quién la consume |
|---|---|---|
| **Bronze** | Guardar los datos **tal cual llegan** de la fuente | Nadie directamente |
| **Silver** | Dejarlos **confiables**: tipos, texto limpio, sin duplicados | Otros modelos |
| **Gold** | Responder **preguntas de negocio** | Dashboards y analistas |

En la vida real bronze lo llena una herramienta de ingesta (Adverity, Fivetran, Airbyte…). Aquí lo simulamos con un **seed**: un CSV que dbt sube a BigQuery.

### Los tres entornos (targets)

El **mismo código** de dbt corre en tres lugares. Solo cambia dónde escribe y con qué identidad:

| Target | Quién lo usa | Datasets | Identidad |
|---|---|---|---|
| `dev` | Tú, en tu máquina | `trendy_dev_bronze/silver/gold` | Tu cuenta |
| `ci` | GitHub, en cada PR | `trendy_ci_bronze/silver/gold` | `trendy-deployer` |
| `prod` | Cloud Run, todos los días | `trendy_bronze/silver/gold` | `trendy-runner` |

### Las identidades

En GCP los programas no usan tu cuenta: usan **service accounts** (SA). Cada una recibe solo lo que necesita (**mínimo privilegio**):

| Service account | Quién la usa | Puede | No puede |
|---|---|---|---|
| `trendy-runner` | Cloud Run, al ejecutar dbt | Correr consultas y escribir en `trendy_*` | Tocar CI ni otros clientes |
| `trendy-deployer` | GitHub Actions | Escribir en `trendy_ci_*`, subir imágenes, actualizar el job | Escribir en producción |
| `trendy-scheduler` | Cloud Scheduler | Ejecutar el job | Cambiar el job |
| `trendy-terraform` | Terraform, por suplantación | Crear la infraestructura de Trendy (9 roles) | Leer el state de otros clientes o de bootstrap |

### El flujo completo

```
Tu máquina    uv run dbt build                                 ──► trendy_dev_*   (tu cuenta)

PR abierto    ci.yml ─ Workload Identity ─► dbt build --target ci  ──► trendy_ci_*    (trendy-deployer)
                    └─ terraform fmt + validate (terraform/ y terraform/bootstrap/)

Merge a main  deploy.yml ─ docker build ─► Artifact Registry ─► actualiza el Cloud Run Job

06:00 diario  Cloud Scheduler ──► Cloud Run Job ──► dbt build --target prod ──► trendy_*
              (trendy-scheduler)  (trendy-runner)

Infra         terraform apply  suplantando a trendy-terraform
Plataforma    terraform/bootstrap/ (admin) ──► bucket del state + SA de Terraform por cliente
```

### Estructura final del repo

```
gcp_dbt_model/
├── .github/workflows/
│   ├── ci.yml                    ← en cada PR
│   └── deploy.yml                ← en cada merge a main
├── docs/ROADMAP.md               ← esta guía
├── models/
│   ├── silver/  stg_meta_ads.sql, _silver.yml
│   └── gold/    fct_campaign_performance.sql, _gold.yml
├── seeds/bronze_meta_ads.csv
├── terraform/
│   ├── bootstrap/                ← capa de plataforma (la aplica el admin)
│   │   ├── versions.tf  variables.tf  state.tf  apis.tf  clients.tf
│   ├── versions.tf  variables.tf  apis.tf
│   ├── bigquery.tf  iam.tf
│   ├── artifact_registry.tf  cloud_run.tf  scheduler.tf
│   ├── workload_identity.tf  outputs.tf
│   └── terraform.tfvars.example
├── .dockerignore  .gitignore  .python-version
├── Dockerfile
├── dbt_project.yml  packages.yml  package-lock.yml  profiles.yml
├── pyproject.toml  uv.lock
└── README.md
```

---

## Parte II · Preparación

## Etapa 0 · Cuentas y herramientas

**Objetivo:** tener las herramientas instaladas y poder cambiar entre cuentas (por ejemplo, trabajo y personal) sin mezclarlas.

### 0.1 · Herramientas

| Herramienta | Versión usada | Para qué |
|---|---|---|
| [Google Cloud SDK](https://cloud.google.com/sdk/docs/install) (`gcloud`) | 568 | Autenticación y verificaciones |
| [Terraform](https://developer.hashicorp.com/terraform/install) | 1.15 (mínimo 1.6) | Infraestructura |
| [uv](https://docs.astral.sh/uv/) | 0.13.0 | Python 3.12 y dependencias |
| [git](https://git-scm.com/) | 2.54 | Código |
| Docker | **No hace falta** | La imagen la construye GitHub Actions |

También necesitas:
- Un **proyecto de GCP con facturación activa** donde seas **owner**.
- Una **cuenta de GitHub**.

### 0.2 · Perfiles de gcloud

Un **perfil** (configuration) guarda cuenta, proyecto y región. Con varios perfiles cambias de contexto con un solo comando.

Si ya usas gcloud con una cuenta de trabajo, tu perfil se llama `default`. No se puede renombrar el perfil activo, así que primero crea el nuevo, que queda activo, y después renombra el viejo:

```powershell
gcloud config configurations create personal
gcloud config configurations rename default --new-name=trabajo
```

Configura el perfil personal e inicia sesión. Los comandos de `login` abren el navegador:

```powershell
gcloud auth login erriick1122@gmail.com
gcloud config set project emra-co
gcloud config set compute/region us-central1
gcloud auth application-default login
gcloud auth application-default set-quota-project emra-co
```

| Comando | Para qué |
|---|---|
| `gcloud auth login` | Sesión de **gcloud** |
| `gcloud auth application-default login` | Credenciales para **Terraform y dbt** (ADC, "Application Default Credentials") |
| `set-quota-project` | Qué proyecto paga las llamadas a las APIs; evita advertencias de cuota |

Para cambiar de perfil:

```powershell
gcloud config configurations activate personal
gcloud config configurations activate trabajo
gcloud config configurations list
```

> ⚠️ **Trampa:** Terraform y dbt **no** usan el perfil de gcloud, sino las ADC, y solo hay unas a la vez. Cada vez que cambies de perfil para trabajar con Terraform o dbt, repite `gcloud auth application-default login` con la cuenta correspondiente.

### 0.3 · SSH para GitHub (varias cuentas)

Con una llave SSH por cuenta y un **alias** por llave, git sabe con qué cuenta conectarse según la URL.

Genera la llave y súbela a GitHub (**Settings → SSH and GPG keys → New SSH key**, pegando el contenido del `.pub`):

```powershell
ssh-keygen -t ed25519 -C "erriick1122@gmail.com" -f $HOME\.ssh\id_personal
Get-Content $HOME\.ssh\id_personal.pub
```

Crea o edita `~/.ssh/config` (en Windows, `C:\Users\<tu-usuario>\.ssh\config`):

```
Host github-personal
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_personal
    IdentitiesOnly yes

Host github-trabajo
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_trabajo
    IdentitiesOnly yes
```

Prueba cada alias:

```powershell
ssh -T git@github-personal
```

Debe responder `Hi <tu-usuario>! You've successfully authenticated…`. Que termine con código de salida 1 es normal: GitHub no da shell.

**Cómo se usa:** en la URL del repo, donde normalmente iría `github.com`, pones el alias:

```
git@github-personal:emrangel/gcp_dbt_model.git     ← cuenta personal
git@github-trabajo:empresa/otro-repo.git           ← cuenta de trabajo
```

Como no tienes `user.name`/`user.email` globales en git, cada repo define su identidad (lo hacemos en la Etapa 1).

### 0.4 · uv

Instálalo con el instalador oficial:

```powershell
powershell -ExecutionPolicy ByPass -c "irm https://astral.sh/uv/install.ps1 | iex"
```

> ⚠️ **Trampa:** después de instalar, **cierra VS Code por completo** (todas las ventanas) y vuelve a abrirlo. Sus terminales heredan el PATH de cuando se abrió, y dirán `uv : The term 'uv' is not recognized`. Abrir otra terminal dentro de VS Code no basta. Como alternativa temporal: `$env:Path = "$env:USERPROFILE\.local\bin;$env:Path"`.

**Detrás de un proxy corporativo** que intercepta HTTPS, uv falla con `invalid peer certificate: UnknownIssuer`. Dile que use los certificados de Windows, una sola vez:

```powershell
setx UV_SYSTEM_CERTS 1
```

Aplica a las terminales que abras después.

### ✅ Checkpoint Etapa 0

- `ssh -T git@github-personal` responde `Hi <tu-usuario>`.
- `gcloud projects describe emra-co` funciona con el perfil personal.
- `gcloud billing projects describe emra-co` muestra `billingEnabled: true`.
- `uv --version` responde en una terminal nueva.

---

## Parte III · dbt en tu máquina

> **¿Por qué dbt antes que Terraform?** Para separar problemas. Si el SQL ya funciona en tu máquina, cualquier error posterior en la nube es de infraestructura (permisos, imagen, Cloud Run) y no del SQL. Además, dbt local no necesita nada de lo que crea Terraform: usa tu cuenta y crea sus propios datasets `trendy_dev_*`. Es la prueba más rápida y barata.

## Etapa 1 · Base del proyecto

**Objetivo:** un proyecto Python con dbt instalado y versionado, y un `.gitignore` que proteja desde el principio.

### 1.1 · Crear la carpeta

```powershell
mkdir gcp_dbt_model
cd gcp_dbt_model
```

Si tienes activado el entorno virtual de otro proyecto (el prompt empieza con `(algo)`), desactívalo con `deactivate` para no mezclar.

### 1.2 · Crear el proyecto Python

```powershell
uv init --bare --python 3.12
uv python pin 3.12
```

- `--bare` crea **solo** `pyproject.toml` (sin `main.py` ni README de ejemplo).
- `--python 3.12` y `uv python pin 3.12` fijan la versión; `pin` crea `.python-version`. Es la misma versión que usarán Docker y CI.

### 1.3 · Agregar dbt

```powershell
uv add "dbt-bigquery~=1.12.1"
uv run dbt --version
```

`uv add` hace tres cosas a la vez:
1. Escribe la dependencia en `pyproject.toml`.
2. Resuelve las ~106 dependencias y genera **`uv.lock`** con las versiones exactas.
3. Crea `.venv` y lo instala todo.

`~=1.12.1` significa "1.12.x, desde la 1.12.1": acepta parches pero no la 1.13, que podría cambiar comportamientos.

El `pyproject.toml` resultante:

```toml
[project]
name = "gcp-dbt-model"
version = "0.1.0"
requires-python = ">=3.12"
dependencies = [
    "dbt-bigquery~=1.12.1",
]
```

**`uv run`** es de uv, no de dbt: significa "ejecuta este comando dentro del entorno de este proyecto". Antes de ejecutar, revisa que `.venv` coincida con `uv.lock` y, si falta algo (por ejemplo después de un `git pull`), lo instala. Por eso no hace falta activar el entorno.

| Forma de correr dbt | Ejemplo | Comentario |
|---|---|---|
| `uv run` (recomendada) | `uv run dbt build` | No hay que activar nada; el entorno siempre está al día |
| Activar el entorno | `.venv\Scripts\activate` y luego `dbt build` | Si olvidas activarlo, o activas el de otro proyecto, usas otro dbt |
| Ruta directa | `.venv\Scripts\dbt.exe build` | Explícito pero incómodo |

### 1.4 · Iniciar git

```powershell
git init -b main
git config user.name "Erick Rangel"
git config user.email "erriick1122@gmail.com"
```

Sin `--global`: la identidad aplica **solo a este repo**, así no se mezcla con la de trabajo.

### 1.5 · `.gitignore`

```gitignore
# Python: el entorno se recrea con "uv sync"
.venv/

# dbt: todo esto lo generan los comandos de dbt
target/
dbt_packages/
logs/
**/.user.yml

# Terraform: en cualquier carpeta (terraform/, terraform/bootstrap/, ...)
**/.terraform/
**/terraform.tfvars
**/tfplan
**/*.tfstate
**/*.tfstate.*
```

| Regla | Por qué |
|---|---|
| `.venv/` | Tu entorno de Windows; cualquiera lo recrea con `uv sync` |
| `target/`, `dbt_packages/`, `logs/` | Los generan los comandos de dbt |
| `**/.user.yml` | dbt guarda ahí un identificador anónimo |
| `**/.terraform/` | El proveedor de Google descargado (~100 MB) |
| `**/terraform.tfvars` | Tus valores reales |
| `**/tfplan` | El plan guardado; puede contener datos del state |
| `**/*.tfstate*` | Por si algún día corres Terraform con state local: puede contener datos sensibles |

`**/` significa "en cualquier carpeta". Sin eso, una regla como `terraform/*.tfstate` **no** cubriría `terraform/bootstrap/`. Ajusta siempre el `.gitignore` **antes** de generar archivos que no deben subirse.

**No** ignoramos `package-lock.yml` (Etapa 5): fija la versión de los paquetes de dbt y tiene que subirse.

### ✅ Checkpoint Etapa 1

```powershell
git status
```

Muestra 4 archivos sin seguimiento: `.gitignore`, `.python-version`, `pyproject.toml` y `uv.lock`. **No** aparece `.venv`.

```powershell
git add .
git commit -m "Etapa 1: base del proyecto con uv"
```

---

## Etapa 2 · dbt conectado a BigQuery

**Objetivo:** que `dbt debug` pase **sin ningún modelo**, probando solo la conexión.

### 2.1 · `dbt_project.yml`

```yaml
name: 'trendy'
version: '1.0.0'

# Qué bloque de profiles.yml usar para conectarse
profile: 'trendy'

# Dónde buscar cada tipo de archivo
model-paths: ["models"]
seed-paths: ["seeds"]
macro-paths: ["macros"]
test-paths: ["tests"]

# Lo que borra "dbt clean"
clean-targets: ["target", "dbt_packages"]
```

- `name`: nombre interno del proyecto. Solo minúsculas y guiones bajos.
- `profile`: el **puente** con `profiles.yml`: "busca ahí el bloque llamado `trendy`".
- La configuración de capas todavía no va; se agrega cuando cada capa exista.

### 2.2 · `profiles.yml` en la raíz

dbt busca `profiles.yml` primero **en la carpeta donde lo ejecutas**. Si lo pones en la raíz del proyecto no necesitas definir `DBT_PROFILES_DIR`, ni en tu máquina ni en Docker.

```yaml
# Sin secretos: usa las credenciales de Google del entorno (ADC)
trendy:
  target: dev
  outputs:
    dev:
      type: bigquery
      method: oauth
      project: "{{ env_var('GCP_PROJECT', 'emra-co') }}"
      dataset: trendy_dev
      location: US
      threads: 4
      maximum_bytes_billed: 1000000000
```

| Línea | Significado |
|---|---|
| `trendy:` | Nombre del bloque; coincide con `profile:` de `dbt_project.yml` |
| `target: dev` | Target por defecto cuando no pasas `--target` |
| `type: bigquery` | Adaptador; por eso instalamos `dbt-bigquery` |
| `method: oauth` | Usa las ADC de `gcloud auth application-default login` |
| `project: "{{ env_var(...) }}"` | Jinja: lee `GCP_PROJECT`; si no existe, usa `emra-co` |
| `dataset: trendy_dev` | **Prefijo** de los datasets: con las capas quedará `trendy_dev_bronze`, etc. |
| `location: US` | Dónde se crean los datasets; debe coincidir con tus fuentes |
| `threads: 4` | Cuántos modelos construye en paralelo |
| `maximum_bytes_billed` | Freno de costos: cancela cualquier consulta que lea más de 1 GB |

Este archivo **sí se sube a git**: no tiene secretos, y CI y Docker lo necesitan.

### 2.3 · Probar

```powershell
gcloud config configurations activate personal
uv run dbt debug
```

### ✅ Checkpoint Etapa 2

```
profiles.yml file [OK found and valid]
dbt_project.yml file [OK found and valid]
Connection test: [OK connection ok]
All checks passed!
```

Sin haber definido `DBT_PROFILES_DIR`.

```powershell
git add .
git commit -m "Etapa 2: proyecto dbt conectado a BigQuery"
```

---

## Etapa 3 · Bronze: los datos crudos

**Objetivo:** simular una exportación cruda de Meta Ads, con todos sus defectos.

### 3.1 · `seeds/bronze_meta_ads.csv`

```powershell
mkdir seeds
```

```csv
date,campaign_id,campaign_name,country,impressions,clicks,spend,_loaded_at
2026-10-01,2001,TRD_Verano_Prospecting,cr,50000,900,420.50,2026-10-02 03:00:00
2026-10-01,2001,TRD_Verano_Prospecting,cr,50000,900,420.50,2026-10-02 05:00:00
2026-10-01,2002,TRD_Verano_Retargeting, CR ,12000,480,150.00,2026-10-02 03:00:00
2026-10-01,2003,TRD_BlackFriday_Teaser,mx,80000,1200,610.75,2026-10-02 03:00:00
2026-10-02,2001,TRD_Verano_Prospecting,cr,52000,950,435.20,2026-10-03 03:00:00
2026-10-02,2002,TRD_Verano_Retargeting,CR,11500,,148.30,2026-10-03 03:00:00
2026-10-02,2003,TRD_BlackFriday_Teaser,MX,82000,1250,620.00,2026-10-03 03:00:00
2026-10-02,2004,  TRD_Colombia_Launch,co,30000,600,280.00,2026-10-03 03:00:00
```

**Los errores puestos a propósito** (silver tendrá que corregirlos):

| Fila | Error | Por qué pasa en la vida real |
|---|---|---|
| 1 y 2 | **Duplicado:** misma campaña y fecha, cargada a las 3:00 y a las 5:00 | La herramienta reintentó la carga |
| 3 | **Espacios:** `" CR "` | Error al escribir en la plataforma |
| varias | **Mayúsculas mezcladas:** `cr`, `CR`, `mx`, `MX` | Distintas fuentes o versiones de la API |
| 6 | **Clicks vacío:** `,,` | La API no devolvió el dato |
| 8 | **Espacios al inicio:** `"  TRD_Colombia_Launch"` | Copiar y pegar desde Excel |

`_loaded_at` es **cuándo llegó** la fila a bronze, no la fecha del dato. El guion bajo inicial marca columnas técnicas que no vienen de Meta. Sirve para decidir qué duplicado conservar.

### 3.2 · Configurar los seeds en `dbt_project.yml`

Agrega al final, en una línea nueva:

```yaml
seeds:
  trendy:
    +schema: bronze
    bronze_meta_ads:
      # En bronze todo llega como texto, como un dump crudo
      +column_types:
        date: string
        campaign_id: string
        campaign_name: string
        country: string
        impressions: string
        clicks: string
        spend: string
        _loaded_at: string
```

| Nivel | Significado |
|---|---|
| `seeds:` | Configuración de todos los seeds |
| `trendy:` | Los seeds **de este proyecto**; igual al `name:` |
| `+schema: bronze` | Manda los seeds al dataset `<dataset>_bronze`. El `+` aplica a todo lo de abajo |
| `bronze_meta_ads:` | Solo ese archivo (nombre del CSV sin `.csv`) |
| `+column_types` | Fuerza el tipo de cada columna |

**¿Por qué todo `string`?** Si no, dbt adivinaría tipos. Un bronze real casi siempre llega como texto, y **convertir tipos es trabajo de silver**.

**Cómo se forma el nombre del dataset:**

```
profiles.yml           dbt_project.yml
dataset: trendy_dev  +  schema: bronze   →   trendy_dev_bronze
```

Por eso el mismo código escribe en `trendy_ci_bronze` en CI y en `trendy_bronze` en prod: solo cambia el `dataset` del target.

### 3.3 · Cargar y mirar

```powershell
uv run dbt seed
uv run dbt show --inline "select * from {{ ref('bronze_meta_ads') }}" --limit 10
```

- `dbt show` ejecuta una consulta y **muestra el resultado sin crear nada**. Por defecto muestra 5 filas; `--limit` cambia eso.
- `{{ ref('bronze_meta_ads') }}` se traduce a `` `emra-co`.`trendy_dev_bronze`.`bronze_meta_ads` ``. **Nunca** escribas nombres de tablas a mano: usa siempre `ref()`, así dbt conoce las dependencias y el orden.

### ✅ Checkpoint Etapa 3

- `1 of 1 OK loaded seed file trendy_dev_bronze.bronze_meta_ads ... [INSERT 8 ...]`
- En el `dbt show` se ven el `" CR "` con espacios y la celda de clicks vacía.

```powershell
git add .
git commit -m "Etapa 3: seed de bronze"
```

---

## Etapa 4 · Silver: limpiar y probar

**Objetivo:** tipos correctos, texto normalizado, sin duplicados, y tests que lo demuestran.

### 4.1 · Configurar la capa en `dbt_project.yml`

Agrega al final:

```yaml
models:
  trendy:
    silver:
      +schema: silver
      +materialized: view
```

- `silver:` corresponde a la **carpeta** `models/silver/`: todo lo que pongas ahí hereda esta configuración.
- `+materialized: view` crea **vistas**: silver es un paso intermedio y una vista no ocupa almacenamiento. Si los datos crecen mucho, se convierte en `incremental` (ver [Preguntas](#dbt-sirve-para-spark-o-grandes-volúmenes)).

### 4.2 · El modelo: `models/silver/stg_meta_ads.sql`

```powershell
mkdir models\silver
mkdir tests
```

```sql
-- SILVER: tipos correctos, texto limpio y sin duplicados

with bronze as (

    select * from {{ ref('bronze_meta_ads') }}

),

typed as (

    select
        safe_cast(date as date)                      as report_date,
        safe_cast(campaign_id as int64)              as campaign_id,
        trim(campaign_name)                          as campaign_name,
        upper(trim(country))                         as country_code,
        coalesce(safe_cast(impressions as int64), 0) as impressions,
        coalesce(safe_cast(clicks as int64), 0)      as clicks,
        coalesce(safe_cast(spend as numeric), 0)     as spend,
        safe_cast(_loaded_at as timestamp)           as loaded_at
    from bronze

),

deduped as (

    -- Si la misma fila llegó dos veces, nos quedamos con la carga más reciente
    select *
    from typed
    qualify row_number() over (
        partition by report_date, campaign_id
        order by loaded_at desc
    ) = 1

)

select * from deduped
```

Tres bloques **CTE** (`with ... as`), cada uno con una sola tarea, que se leen de arriba hacia abajo:

**`bronze`:** solo trae los datos. Convención de dbt: las referencias van al principio, así se ve de qué depende el modelo.

**`typed`:** corrige cada error del CSV.

| Función | Qué hace | Corrige |
|---|---|---|
| `safe_cast(x as date)` | Texto → fecha; si no puede, `NULL` en vez de fallar | Todo llega como texto |
| `trim(...)` | Quita espacios al inicio y al final | `"  TRD_Colombia_Launch"` |
| `upper(trim(country))` | Quita espacios y pasa a mayúsculas | `" CR "`, `cr`, `mx` |
| `coalesce(x, 0)` | Si es `NULL`, usa 0 | Clicks vacíos |
| `as report_date` | Renombra | `date` es palabra reservada |

- **`safe_cast` vs `cast`:** `cast('abc' as int64)` hace fallar **toda la consulta**; `safe_cast` deja esa celda en `NULL` y los tests `not_null` la detectan. Un dato malo no tumba el pipeline, pero tampoco pasa sin que lo veas.
- **Decisión de negocio:** `coalesce(clicks, 0)` asume "si no sé cuántos clicks hubo, fueron 0". Es discutible: un dato faltante no es cero. En un proyecto real se conversa con quien usa los datos.

**`deduped`:** elimina duplicados.

```
row_number() over (partition by report_date, campaign_id order by loaded_at desc)
```

| report_date | campaign_id | loaded_at | row_number |
|---|---|---|---|
| 2026-10-01 | 2001 | 05:00 | **1** ← se queda |
| 2026-10-01 | 2001 | 03:00 | 2 ← se elimina |

`qualify ... = 1` es un `where` para funciones de ventana (BigQuery y Snowflake; en otros motores se usa una subconsulta).

### 4.3 · Documentación y tests: `models/silver/_silver.yml`

```yaml
version: 2

models:
  - name: stg_meta_ads
    description: "Meta Ads diario por campaña, tipado y deduplicado."
    columns:
      - name: report_date
        description: "Fecha del dato en Meta Ads."
        data_tests: [not_null]
      - name: campaign_id
        data_tests: [not_null]
      - name: country_code
        description: "País en ISO-2 mayúsculas."
        data_tests:
          - accepted_values:
              arguments:
                values: ['CR', 'MX', 'CO', 'PA', 'GT']
```

- `name` debe ser igual al nombre del archivo `.sql`.
- Las `description` aparecen en `dbt docs`.
- `not_null` atrapa los `NULL` que pudo dejar `safe_cast`.
- `accepted_values` falla si llega un país inesperado como `VE` o `"C R"`.
- El guion bajo en `_silver.yml` hace que el archivo aparezca primero en la carpeta.

### 4.4 · Un test propio: `tests/assert_stg_meta_ads_unique.sql`

Los tests del YAML revisan una columna a la vez. Para revisar la **combinación** fecha + campaña:

```sql
-- Falla si alguna combinación de fecha + campaña aparece más de una vez
select
    report_date,
    campaign_id,
    count(*) as filas
from {{ ref('stg_meta_ads') }}
group by report_date, campaign_id
having count(*) > 1
```

**Regla de oro: un test es una consulta que busca problemas.** Si devuelve 0 filas, pasa ✅. Si devuelve filas, falla ❌, y esas filas son los casos problemáticos. En la Etapa 5 lo reemplazamos por uno de `dbt_utils` que hace lo mismo.

### 4.5 · Construir solo silver

```powershell
uv run dbt build --select stg_meta_ads
uv run dbt show --select stg_meta_ads --limit 10
```

`--select` construye solo ese modelo y sus tests. Es lo que usarás a diario mientras trabajas en un modelo.

### ✅ Checkpoint Etapa 4

```
OK created sql view model trendy_dev_silver.stg_meta_ads
PASS not_null_stg_meta_ads_report_date
PASS not_null_stg_meta_ads_campaign_id
PASS accepted_values_stg_meta_ads_country_code__CR__MX__CO__PA__GT
PASS assert_stg_meta_ads_unique
Done. PASS=5 WARN=0 ERROR=0 SKIP=0 TOTAL=5
```

Y en el `dbt show`: **7 filas** (se eliminó el duplicado), países en mayúsculas sin espacios, `0` en los clicks vacíos y `TRD_Colombia_Launch` sin espacios.

### 🔨 Experimento: romperlo a propósito

Quita `'CO'` de `accepted_values` y repite el build. Verás:

```
FAIL 1 accepted_values_stg_meta_ads_country_code__CR__MX__PA__GT
Got 1 result, configured to fail if != 0
```

Ese `1 result` es Colombia. **Vuelve a poner `'CO'`** y confirma que pasa.

```powershell
git add .
git commit -m "Etapa 4: capa silver con tests"
```

---

## Etapa 5 · Gold: KPIs para el negocio

**Objetivo:** una fila por campaña con CTR, CPC y CPM; usar un paquete de dbt y ver el linaje.

### 5.1 · Instalar `dbt_utils`: `packages.yml`

```yaml
packages:
  - package: dbt-labs/dbt_utils
    version: [">=1.3.0", "<2.0.0"]
```

```powershell
uv run dbt deps
```

Crea:
- `dbt_packages/`: el código descargado (ignorado por git).
- **`package-lock.yml`**: la versión exacta instalada. **Se sube a git**, igual que `uv.lock`. Con eso, Python (`uv.lock`), Terraform (`.terraform.lock.hcl`) y los paquetes de dbt (`package-lock.yml`) quedan fijados.

```yaml
packages:
  - name: dbt_utils
    package: dbt-labs/dbt_utils
    version: 1.4.1
sha1_hash: a4da77dcded39caf20bd661f0098cbffd9735800
```

### 5.2 · Reemplazar el test propio

```powershell
del tests\assert_stg_meta_ads_unique.sql
```

`models/silver/_silver.yml` queda así (test a nivel de modelo y `accepted_range` para `spend`):

```yaml
version: 2

models:
  - name: stg_meta_ads
    description: "Meta Ads diario por campaña, tipado y deduplicado."
    data_tests:
      - dbt_utils.unique_combination_of_columns:
          arguments:
            combination_of_columns: [report_date, campaign_id]
    columns:
      - name: report_date
        description: "Fecha del dato en Meta Ads."
        data_tests: [not_null]
      - name: campaign_id
        data_tests: [not_null]
      - name: country_code
        description: "País en ISO-2 mayúsculas."
        data_tests:
          - accepted_values:
              arguments:
                values: ['CR', 'MX', 'CO', 'PA', 'GT']
      - name: spend
        data_tests:
          - dbt_utils.accepted_range:
              arguments:
                min_value: 0
```

| Test | Nivel | Revisa |
|---|---|---|
| `unique_combination_of_columns` | Modelo | Que no se repita fecha + campaña (por dentro genera casi el mismo SQL del test propio) |
| `accepted_range` | Columna | Que `spend` nunca sea negativo |

Escribe tests propios para reglas **de tu negocio** (por ejemplo, "el spend diario no supera el presupuesto"); para reglas genéricas, usa `dbt_utils`.

### 5.3 · Configurar la capa gold

En `dbt_project.yml`, dentro de `models: → trendy:`, al mismo nivel que `silver`:

```yaml
models:
  trendy:
    silver:
      +schema: silver
      +materialized: view
    gold:
      +schema: gold
      +materialized: table
```

**¿Por qué tabla?** Gold lo leen los dashboards muchas veces al día. Una tabla calcula los KPIs una vez (cuando corre dbt) y cada lectura es rápida y barata. Una vista recalcularía todo en cada clic.

| | Vista (silver) | Tabla (gold) |
|---|---|---|
| ¿Guarda datos? | No, solo la consulta | Sí, el resultado |
| ¿Cuándo se calcula? | Cada vez que alguien la lee | Cuando corre `dbt build` |
| Costo de leerla | La consulta completa | Solo leer la tabla |

### 5.4 · El modelo: `models/gold/fct_campaign_performance.sql`

```powershell
mkdir models\gold
```

```sql
-- GOLD: una fila por campaña con KPIs listos para el dashboard

with silver as (

    select * from {{ ref('stg_meta_ads') }}

)

select
    campaign_id,
    campaign_name,
    country_code,
    min(report_date)                                  as first_date,
    max(report_date)                                  as last_date,
    sum(impressions)                                  as impressions,
    sum(clicks)                                       as clicks,
    sum(spend)                                        as spend,
    safe_divide(sum(clicks), sum(impressions))        as ctr,
    safe_divide(sum(spend), sum(clicks))              as cpc,
    safe_divide(sum(spend), sum(impressions)) * 1000  as cpm
from silver
group by campaign_id, campaign_name, country_code
```

| KPI | Fórmula | Responde |
|---|---|---|
| **CTR** (Click-Through Rate) | clicks ÷ impresiones | ¿Qué porcentaje hizo clic? |
| **CPC** (Costo por Clic) | spend ÷ clicks | ¿Cuánto cuesta cada clic? |
| **CPM** (Costo por Mil) | spend ÷ impresiones × 1000 | ¿Cuánto cuesta mostrar el anuncio mil veces? |

- **`safe_divide`:** con 0 clicks, `spend / clicks` daría error de división por cero y fallaría todo el modelo; `safe_divide` devuelve `NULL`.
- **Sumar primero, dividir después:** `sum(clicks) / sum(impressions)` y **no** el promedio de los CTR diarios. Promediar le daría el mismo peso a un día con 10 impresiones que a uno con 100.000.
- **Nombres:** `fct_` = tabla de **hechos** (métricas que se suman); `stg_` = staging (silver); `dim_` sería una dimensión (atributos).

### 5.5 · Tests de gold: `models/gold/_gold.yml`

```yaml
version: 2

models:
  - name: fct_campaign_performance
    description: "KPIs acumulados por campaña de Meta Ads (CTR, CPC, CPM)."
    columns:
      - name: campaign_id
        description: "Una fila por campaña: este es el grano de la tabla."
        data_tests: [unique, not_null]
      - name: ctr
        description: "clicks / impressions"
        data_tests:
          - dbt_utils.accepted_range:
              arguments:
                min_value: 0
                max_value: 1
```

- **`unique` en `campaign_id` protege el grano.** El *grano* es qué representa una fila (aquí, una campaña). Si una campaña corriera en dos países, el `group by` generaría dos filas y este test avisaría.
- **CTR entre 0 y 1:** es imposible tener más clicks que impresiones; si pasa, el error está en el origen.

### 5.6 · Construir todo

```powershell
uv run dbt build
uv run dbt show --select fct_campaign_performance
```

### 5.7 · Ver el linaje

```powershell
uv run dbt docs generate
uv run dbt docs serve
```

Se abre `localhost:8080`. El ícono azul abajo a la derecha muestra el grafo `bronze_meta_ads → stg_meta_ads → fct_campaign_performance`, construido por dbt leyendo tus `ref()`. `Ctrl + C` para cerrar.

### ✅ Checkpoint Etapa 5

```
Done. PASS=11 WARN=0 ERROR=0 SKIP=0 TOTAL=11
```

1 seed + 2 modelos + 8 tests (5 de silver + 3 de gold).

**Verifica una fila a mano** con el CSV (sin el duplicado). Campaña 2001:

| | Cálculo | Resultado |
|---|---|---|
| Impresiones | 50.000 + 52.000 | **102.000** |
| Clicks | 900 + 950 | **1.850** |
| Spend | 420,50 + 435,20 | **855,70** |
| CTR | 1.850 ÷ 102.000 | **0,0181** (1,81%) |

Si salen 152.000 impresiones, el duplicado no se eliminó.

Resultado completo esperado:

| campaign_id | impressions | clicks | spend | ctr |
|---|---|---|---|---|
| 2001 | 102000 | 1850 | 855.70 | 0.0181 |
| 2002 | 23500 | 480 | 298.30 | 0.0204 |
| 2003 | 162000 | 2450 | 1230.75 | 0.0151 |
| 2004 | 30000 | 600 | 280.00 | 0.0200 |

(La 2002 tiene 480 clicks porque el segundo día llegó vacío y `coalesce` lo convirtió en 0.)

```powershell
git add .
git status          # debe incluir package-lock.yml
git commit -m "Etapa 5: capa gold con KPIs y dbt_utils"
```

---

## Etapa 6 · Docker

**Objetivo:** empaquetar el proyecto para Cloud Run. Sin Docker local, esta etapa se escribe aquí y se prueba de verdad en la Etapa 9, cuando GitHub construya la imagen.

```
Dockerfile (la receta)  →  docker build  →  imagen (la caja)  →  Cloud Run la ejecuta
```

### 6.1 · Target `prod` en `profiles.yml`

Dentro de `outputs:`, al mismo nivel que `dev:`:

```yaml
    prod:
      type: bigquery
      method: oauth
      project: "{{ env_var('GCP_PROJECT', 'emra-co') }}"
      dataset: "{{ env_var('DBT_DATASET', 'trendy') }}"
      location: US
      threads: 8
      job_execution_timeout_seconds: 1800
```

| Clave | dev | prod | Por qué |
|---|---|---|---|
| `dataset` | `trendy_dev` | `env_var('DBT_DATASET', 'trendy')` | Terraform le pasa `DBT_DATASET` al job desde `prefix`: el nombre se define en un solo lugar |
| `threads` | 4 | 8 | En la nube nadie más usa la máquina |
| `maximum_bytes_billed` | 1 GB | No tiene | En prod los datos reales pueden ser grandes |
| `job_execution_timeout_seconds` | No tiene | 1800 | Cancela una consulta colgada a los 30 minutos |

```powershell
uv run dbt debug --target prod
```

> ⚠️ **No corras `dbt build --target prod`** en tu máquina. Crearía los datasets `trendy_*` con tu usuario y Terraform fallaría después con "already exists". Los datasets de prod los crea Terraform; dbt solo los llena.

### 6.2 · `Dockerfile`

```dockerfile
FROM python:3.12-slim

# Misma versión de uv que en tu máquina
COPY --from=ghcr.io/astral-sh/uv:0.13.0 /uv /bin/uv

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    UV_LINK_MODE=copy \
    PATH="/app/.venv/bin:$PATH"

WORKDIR /app

# Primero solo las dependencias, para que Docker cachee esta capa
COPY pyproject.toml uv.lock .python-version ./
RUN uv sync --locked --no-dev --no-cache

# Después el proyecto
COPY . .
RUN dbt deps

# Cloud Run Job ejecuta esto una vez y termina
ENTRYPOINT ["dbt"]
CMD ["build", "--target", "prod"]
```

| Instrucción | Qué hace |
|---|---|
| `FROM python:3.12-slim` | Imagen oficial: Debian mínimo + Python 3.12 (~150 MB contra ~1 GB de la completa) |
| `COPY --from=ghcr.io/astral-sh/uv:0.13.0 ...` | Copia solo el ejecutable de uv desde su imagen oficial |
| `PYTHONDONTWRITEBYTECODE=1` | No crea archivos `.pyc` |
| `PYTHONUNBUFFERED=1` | Logs **en tiempo real**; sin esto Cloud Run podría mostrarlos tarde o perderlos si el job falla |
| `UV_LINK_MODE=copy` | uv copia en vez de enlazar; evita una advertencia en Docker |
| `PATH="/app/.venv/bin:$PATH"` | Pone el dbt del `.venv` en el PATH: por eso aquí no se usa `uv run` |
| `WORKDIR /app` | Carpeta de trabajo; dbt encuentra `profiles.yml` en `/app` sin `DBT_PROFILES_DIR` |
| `COPY pyproject.toml uv.lock ...` + `uv sync --locked --no-dev --no-cache` | Instala exactamente `uv.lock`; `--locked` falla si el lock no coincide con `pyproject.toml` |
| `COPY . .` | Copia el proyecto, menos lo que excluye `.dockerignore` |
| `RUN dbt deps` | Instala `dbt_utils` con la versión exacta de `package-lock.yml` |
| `ENTRYPOINT ["dbt"]` | El programa que **siempre** se ejecuta |
| `CMD ["build", "--target", "prod"]` | Los argumentos **por defecto**, que se pueden reemplazar |

**Capas y caché.** Docker construye por capas y reutiliza las que no cambiaron:

```
Capa 1: python:3.12-slim                   ← casi nunca cambia
Capa 2: uv                                 ← casi nunca cambia
Capa 3: uv sync (instala dbt, ~2 min)      ← solo cambia si cambia uv.lock
Capa 4: COPY . . (tu SQL)                  ← cambia en cada commit
Capa 5: dbt deps                           ← se rehace después de la capa 4
```

Si cambias un `.sql`, se reutilizan las capas 1–3. Si copiaras todo primero, cada cambio de SQL reinstalaría dbt desde cero.

**`ENTRYPOINT` + `CMD`.** Permiten cambiar **qué** hace dbt sin construir otra imagen. Por ejemplo, reconstruir solo gold:

```powershell
gcloud run jobs execute trendy-dbt --region us-central1 --args="build,--select,fct_campaign_performance,--target,prod"
```

**Los tres "build" que no hay que confundir:**

| Comando | Construye | Cuándo |
|---|---|---|
| `docker build` | La **imagen** (Linux + Python + dbt + proyecto) | Una vez por deploy, en GitHub |
| `uv sync` | El **entorno de Python** | Dentro de `docker build` |
| `dbt build` | Las **tablas en BigQuery** | Cada vez que Cloud Run ejecuta el job |

**¿Por qué en Docker no se usa `uv run`?** En tu máquina el entorno puede estar desactualizado (un `git pull`, otro entorno activado) y `uv run` lo revisa antes de cada comando. En la imagen hay un solo entorno, instalado al construirla desde el mismo `uv.lock`, que ya no cambia y está en el PATH. Revisarlo cada mañana no aportaría nada.

### 6.3 · `.dockerignore`

```
.git
.github
.venv
target
dbt_packages
logs
terraform
*.md
```

| Línea | Por qué |
|---|---|
| `.git` | El historial no sirve para ejecutar dbt |
| `.github` | Los workflows solo los usa GitHub |
| `.venv` | **La más importante:** es tu entorno de **Windows**; la imagen es **Linux** y crea el suyo. Si se copiara, rompería la instalación |
| `target`, `dbt_packages`, `logs` | Generados localmente; la imagen corre su propio `dbt deps` |
| `terraform` | La infraestructura no corre dentro del contenedor |
| `*.md` | Documentación |

**Lo que NO está** y debe entrar: `profiles.yml`, `package-lock.yml` y `uv.lock`.

### ✅ Checkpoint Etapa 6

- `uv run dbt debug --target prod` pasa.
- Puedes responder: si cambio un `.sql`, ¿se reinstala dbt? (No: se reutiliza la capa 3.) ¿Qué pasa si quito `.venv` del `.dockerignore`? (Se copiaría el entorno de Windows a Linux y rompería la imagen.)

```powershell
git add .
git commit -m "Etapa 6: Dockerfile y target prod"
```

---

## Parte IV · Infraestructura con Terraform

### Cómo está organizado

Terraform lee **todos los `.tf` de la carpeta donde lo ejecutas** como si fueran uno solo (no lee subcarpetas). Separamos por tema para encontrar las cosas, y los permisos sobre un recurso específico van **junto a ese recurso**:

| Tipo de permiso | Dónde va |
|---|---|
| SAs y roles de proyecto | `iam.tf` |
| Permisos sobre un recurso (este repo, este job) | El archivo del recurso |

Hay **dos proyectos de Terraform independientes**, cada uno con su state:

| Carpeta | Administra | Quién aplica | Cuándo |
|---|---|---|---|
| `terraform/bootstrap/` | Lo de **plataforma**: bucket del state y SA de Terraform por cliente | El admin, con su cuenta de owner | Una vez, y al agregar un cliente |
| `terraform/` | **Todo lo de Trendy** | `trendy-terraform`, por suplantación | 7A–7D y cambios futuros |

Para saber dónde estás: `dir *.tf`. Si ves `cloud_run.tf`, estás en Trendy; si ves `clients.tf`, en bootstrap.

### Comandos de Terraform

| Comando | ¿Cambia algo en GCP? | Qué hace |
|---|---|---|
| `terraform init` | ❌ | Descarga el proveedor y conecta con el backend (el bucket) |
| `terraform fmt` | ❌ | Ordena la indentación. Córrelo antes de cada commit: el CI falla si no está formateado |
| `terraform validate` | ❌ | Revisa la sintaxis sin conectarse a GCP |
| `terraform console` | ❌ | Consola interactiva para evaluar expresiones |
| `terraform plan -out=tfplan` | ❌ | **Lee** GCP, calcula la diferencia y la guarda |
| **`terraform apply tfplan`** | ✅ | **El único que crea o cambia recursos**: aplica exactamente el plan guardado |
| `terraform state list` / `state show X` | ❌ | Lo que Terraform administra, y el detalle de un recurso |
| `terraform output` | ❌ | Valores calculados (los usa GitHub) |

Escribir un `.tf` o hacer commit **no crea nada**. Solo `apply`.

Si un `apply` falla a mitad de camino (un error de red, una API recién activada que todavía no responde), vuelve a correr `plan -out=tfplan` y `apply tfplan`: el state sabe qué ya existe y solo crea lo que faltó. Un `tfplan` ya aplicado queda desactualizado (*stale*) y no se puede reutilizar.

### Orden y conteo de recursos

| Etapa | Carpeta | Recursos | Resuelve |
|---|---|---|---|
| 7.0 | `bootstrap/` | 15 | **Quién** aplica Terraform, con mínimo privilegio |
| 7A | `terraform/` | 7 | **Dónde** viven los datos |
| 7B | `terraform/` | 12 | **Quién** puede tocar cada dataset |
| 7C | `terraform/` | 11 | **Dónde y cuándo** corre dbt |
| 7D | `terraform/` | 4 | **Cómo** entra GitHub sin llaves |

> **Nota de historia:** al construir este repo, el bucket del state se creó a mano con `gcloud` y el bootstrap se hizo después de la 7B, adoptando el bucket con `import`. Para replicarlo desde cero conviene hacer el bootstrap **primero**, así ningún recurso del cliente se aplica como owner. Esta guía usa ese orden y explica las dos variantes.

---

## Etapa 7.0 · Bootstrap de plataforma

**Objetivo:** crear el bucket del state y la SA `trendy-terraform` con permisos mínimos, y poder suplantarla.

### ¿Por qué una capa aparte?

- **El huevo y la gallina:** Terraform necesita el bucket **antes** de empezar (`init` lee el state de ahí), así que el Terraform que usa ese bucket no puede crearlo. El bootstrap empieza con state **local**, crea el bucket y después mueve su propio state adentro.
- **La SA de Terraform no puede crearse a sí misma:** sería una cuenta que se da sus propios permisos y podría borrarse a sí misma. La crea el admin.
- **Es compartido:** el bucket guarda los states de **todos** los clientes; no pertenece a ninguno.

### 7.0.1 · APIs mínimas

```powershell
gcloud services enable cloudresourcemanager.googleapis.com iam.googleapis.com iamcredentials.googleapis.com --project emra-co
```

| API | Para qué |
|---|---|
| `cloudresourcemanager` | Leer y escribir permisos del proyecto (Terraform no puede funcionar sin ella) |
| `iam` | Crear service accounts |
| `iamcredentials` | Generar tokens al suplantar una SA |

### 7.0.2 · `terraform/bootstrap/versions.tf` (sin backend al principio)

```powershell
mkdir terraform\bootstrap
cd terraform\bootstrap
```

```hcl
terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
  }

  # Sin bloque "backend": el state queda local (terraform.tfstate).
  # En 7.0.6 lo movemos al bucket.
}

# Sin este bloque, Terraform tomaría el proyecto de la configuración local de gcloud
provider "google" {
  project = var.project_id
}
```

| Bloque | Qué hace |
|---|---|
| `required_version` | Exige Terraform 1.6+ |
| `required_providers` | El proveedor `hashicorp/google` le enseña a Terraform qué es cada recurso de GCP; `~> 7.0` acepta cualquier 7.x |
| (sin `backend`) | Sin este bloque el state se guarda en `terraform.tfstate` en esta carpeta |
| `provider "google"` | Proyecto por defecto de los recursos. **No lo omitas:** sin él, Terraform usa el proyecto de tu perfil activo de gcloud y podría aplicar en el proyecto equivocado |

### 7.0.3 · `terraform/bootstrap/variables.tf`

```hcl
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
```

- Usamos `default` en lugar de `terraform.tfvars`: es configuración de **tu plataforma**, no cambia por cliente y no tiene nada que ocultar.
- **`clients`:** para un cliente nuevo, agregas su nombre y aplicas.
- **`admin`:** formato IAM: `user:` para personas, `serviceAccount:` para SAs, `group:` para grupos. En un equipo real iría un **grupo**: si alguien se va, lo sacas del grupo sin tocar Terraform.
- El nombre del bucket es **global en todo GCP**; si ya existe en otra cuenta, elige otro.

### 7.0.4 · `terraform/bootstrap/state.tf`: el bucket

**Variante A · el bucket no existe (desde cero):**

```hcl
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
```

**Variante B · el bucket ya existe (así está en este repo):** agrega este bloque arriba del recurso. Los atributos del recurso deben describir el bucket **exactamente como es**; revísalo antes con `gcloud storage buckets describe gs://emra-co-tfstate`.

```hcl
# El bucket ya existe (lo creamos con gcloud): Terraform lo adopta, no lo crea
import {
  to = google_storage_bucket.tfstate
  id = var.state_bucket
}
```

| Parte | Qué hace |
|---|---|
| `uniform_bucket_level_access` | Permisos solo a nivel de bucket (requisito para las IAM Conditions de abajo) |
| `versioning` | Guarda versiones anteriores de cada state |
| `prevent_destroy = true` | Terraform **se niega** a cualquier operación que destruya el bucket. Perderlo sería perder los states de todos los clientes |
| `import { to, id }` | (Variante B) "Este recurso de mi código corresponde a este que ya existe". Sin `import`, Terraform intentaría crearlo y fallaría con *already exists* |

### 7.0.5 · `terraform/bootstrap/apis.tf`

```hcl
# APIs que necesita la plataforma antes de que cualquier cliente aplique nada
resource "google_project_service" "platform" {
  for_each = toset([
    "cloudresourcemanager.googleapis.com", # leer/escribir permisos del proyecto
    "iamcredentials.googleapis.com",       # generar tokens al suplantar una SA
  ])
  service            = each.value
  disable_on_destroy = false
}
```

Ya las activaste con gcloud en 7.0.1; aquí quedan **declaradas en código**. Terraform solo las registra.

### 7.0.6 · `terraform/bootstrap/clients.tf`: la SA y sus permisos

```hcl
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
```

**Los 9 roles y para qué etapa sirve cada uno:**

| Rol | Para | Etapa |
|---|---|---|
| `serviceusage.serviceUsageAdmin` | Activar APIs | 7A–7D |
| `bigquery.admin` | Datasets y sus permisos | 7A, 7B |
| `iam.serviceAccountAdmin` | SAs y permisos sobre SAs | 7B, 7C, 7D |
| `resourcemanager.projectIamAdmin` | Permisos a nivel de proyecto | 7B, 7C |
| `iam.serviceAccountUser` | Crear un job que corre **como** `trendy-runner` | 7C |
| `artifactregistry.admin` | Repositorio de imágenes | 7C |
| `run.admin` | Cloud Run Job | 7C |
| `cloudscheduler.admin` | Scheduler | 7C |
| `iam.workloadIdentityPoolAdmin` | Pool de GitHub | 7D |

**`setproduct` cliente × rol:** con un cliente salen 9 combinaciones; con dos, 18, sin escribir más. La llave `"trendy|roles/run.admin"` usa `|` porque los nombres de rol tienen `/` y `.`.

**La IAM Condition del state.** Un state puede contener datos sensibles de otros clientes. La condición permite:

| Parte de la expresión | Permite |
|---|---|
| `resource.name.startsWith(".../objects/trendy/")` | Leer, escribir y borrar **solo** objetos bajo `trendy/` |
| `resource.name == ".../buckets/emra-co-tfstate"` | Operaciones sobre el bucket mismo, como **listar nombres** (Terraform lo hace en `init`) |

Trendy puede **ver** que existe `bootstrap/`, pero no leer su contenido. El state donde están sus propios permisos queda fuera de su alcance.

**La suplantación.** `serviceAccountTokenCreator` **sobre la SA** (no sobre el proyecto) permite al admin pedir tokens temporales "como" `trendy-terraform`, y solo de esa SA.

> ⚠️ **Límite conocido:** `projectIamAdmin` permite otorgar cualquier rol del proyecto, incluido Owner, también a sí misma. Se puede limitar con una IAM Condition sobre qué roles puede otorgar (ver [Pendientes](#pendientes)). Y en un proyecto compartido el aislamiento entre clientes es **parcial**: varios roles son de proyecto. El aislamiento real es **un proyecto de GCP por cliente**.

### 7.0.7 · Aplicar con state local

```powershell
terraform init
terraform fmt
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
```

- `init` **no** dice "configured the backend gcs": sin bloque `backend`, usa el backend local.
- **Variante A:** `Plan: 15 to add` (1 bucket + 2 APIs + 1 SA + 9 roles + 1 permiso en el bucket + 1 suplantación).
- **Variante B:** `Plan: 1 to import, 14 to add, 0 to change`. Si aparece `to change` en el bucket, **no apliques**: algún atributo no coincide con la realidad.

### 7.0.8 · 🔨 Experimento: probar `prevent_destroy`

```powershell
terraform plan -destroy
```

Esperado: `Error: Instance cannot be destroyed … lifecycle.prevent_destroy`. Terraform se niega **antes** de tocar nada.

### 7.0.9 · Mover el state al bucket

Agrega el backend a `bootstrap/versions.tf`, dentro de `terraform { }` (y **conserva** el bloque `provider`):

```hcl
  # El state de bootstrap vive en el mismo bucket que administra.
  # Lo aplica el admin con su propia cuenta (sin suplantar).
  backend "gcs" {
    bucket = "emra-co-tfstate"
    prefix = "bootstrap"
  }
```

```powershell
terraform init -migrate-state      # responde: yes
terraform state list               # los mismos 15 recursos, ahora desde el bucket
terraform plan                     # No changes
gcloud storage ls gs://emra-co-tfstate/
```

Solo después de confirmar lo anterior, borra la copia local (ya es vieja y peligrosa):

```powershell
del terraform.tfstate
del terraform.tfstate.backup
```

Guardar el state en el bucket que él mismo administra es seguro: el bucket ya existe (`init` no necesita crearlo) y `prevent_destroy` impide borrarlo.

El bloque `backend` **no admite variables** (se lee antes que todo lo demás); por eso el nombre del bucket va escrito a mano.

### 7.0.10 · 🔍 Probar la suplantación y el aislamiento

Los permisos de IAM tardan de 1 a 7 minutos en propagarse. Si algo da `403` justo después del apply, espera y repite.

```powershell
$SA = "trendy-terraform@emra-co.iam.gserviceaccount.com"
gcloud auth print-access-token --impersonate-service-account=$SA
gcloud storage ls gs://emra-co-tfstate/ --impersonate-service-account=$SA
gcloud storage objects describe gs://emra-co-tfstate/bootstrap/default.tfstate --impersonate-service-account=$SA
```

| Prueba | Esperado | Significa |
|---|---|---|
| `print-access-token` | Un token y una advertencia de suplantación | Puedes actuar como la SA |
| `storage ls` | Las carpetas del bucket | Puede listar nombres |
| `objects describe` de `bootstrap/` | **`403 … storage.objects.get denied`** | **El aislamiento funciona** |

(Cuando exista `trendy/default.tfstate`, el mismo `describe` sobre ese archivo debe funcionar.)

### ✅ Checkpoint Etapa 7.0

- `gs://emra-co-tfstate/bootstrap/default.tfstate` existe y el `terraform.tfstate` local ya no.
- La SA genera token y recibe `403` al leer un state que no es suyo.

```powershell
cd ..\..
git add .
git status      # NO debe aparecer ningún .tfstate ni tfplan
git commit -m "Etapa 7.0: bootstrap con bucket del state y SA trendy-terraform"
```

---

## Etapa 7A · Configuración base y datasets

**Objetivo:** los 6 datasets de ci y prod, aplicados como `trendy-terraform`.

```powershell
cd terraform
```

### 7A.1 · `terraform/versions.tf`

```hcl
terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
  }

  # El state lo lee y escribe trendy-terraform, no tu cuenta
  backend "gcs" {
    bucket                      = "emra-co-tfstate"
    prefix                      = "trendy"
    impersonate_service_account = "trendy-terraform@emra-co.iam.gserviceaccount.com"
  }
}

# Los recursos los crea trendy-terraform, no tu cuenta
provider "google" {
  project                     = var.project_id
  region                      = var.region
  impersonate_service_account = "${var.prefix}-terraform@${var.project_id}.iam.gserviceaccount.com"
}
```

La suplantación va en **dos lugares** porque son dos conexiones distintas a GCP:

| Lugar | Hace | Sin suplantación usaría |
|---|---|---|
| `backend "gcs"` | Lee y escribe el **state** | Tu cuenta de owner |
| `provider "google"` | Crea y modifica **recursos** | Tu cuenta de owner |

En el backend va escrito a mano porque **no admite variables**; en el provider se arma con variables.

```
Tu ADC (erriick1122) ──"quiero ser trendy-terraform"──► API iamcredentials
                                                           │ ¿tiene tokenCreator sobre esa SA? ✅
                     ◄────── token temporal (1 hora) ──────┘
Terraform usa ese token para TODO: GCP ve a trendy-terraform, no a ti
```

El state queda en `gs://emra-co-tfstate/trendy/default.tfstate`, separado de los demás.

### 7A.2 · `terraform/variables.tf`

```hcl
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
```

Con `default`, la variable es opcional; sin `default` (`project_id`, `prefix`) es obligatoria. En 7C y 7D se agregan más.

### 7A.3 · `terraform/terraform.tfvars`

```powershell
copy terraform.tfvars.example terraform.tfvars
```

```hcl
project_id = "emra-co"
prefix     = "trendy"
```

Terraform lo lee automáticamente. **No se sube a git.** `terraform.tfvars.example` sí se sube, como plantilla.

### 7A.4 · `terraform/apis.tf`

```hcl
locals {
  # Vamos agregando APIs a medida que cada parte las necesite
  apis = [
    "bigquery.googleapis.com",
  ]
}

resource "google_project_service" "apis" {
  for_each           = toset(local.apis)
  service            = each.value
  disable_on_destroy = false
}
```

```
resource "google_project_service" "apis" {
          └──────────┬─────────┘  └─┬─┘
          tipo (qué es en GCP)    nombre interno en Terraform
```

| Parte | Significado |
|---|---|
| `locals { }` | Valores calculados internos (no se configuran desde fuera) |
| `for_each = toset(...)` | Un recurso por cada elemento; la lista crece en 7B–7D sin cambiar el bloque |
| `each.value` | El elemento actual |
| `disable_on_destroy = false` | Un `destroy` **no apaga** la API. Esencial en un proyecto compartido: otros proyectos la usan |

### 7A.5 · `terraform/bigquery.tf`

```hcl
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
```

**El mapa `datasets`, paso a paso:**

1. `keys(local.envs)` → `["ci", "prod"]`
2. `setproduct(["ci","prod"], ["bronze","silver","gold"])` → 6 pares: `["ci","bronze"]` … `["prod","gold"]`
3. Por cada par, una entrada con llave `"ci_bronze"` y valor `{ env = "ci", dataset_id = "trendy_ci_bronze" }`

```
{
  ci_bronze   = { env = "ci",   dataset_id = "trendy_ci_bronze" }
  ci_silver   = { env = "ci",   dataset_id = "trendy_ci_silver" }
  ci_gold     = { env = "ci",   dataset_id = "trendy_ci_gold" }
  prod_bronze = { env = "prod", dataset_id = "trendy_bronze" }
  prod_silver = { env = "prod", dataset_id = "trendy_silver" }
  prod_gold   = { env = "prod", dataset_id = "trendy_gold" }
}
```

| Línea | Qué hace |
|---|---|
| `labels` | Etiquetas visibles en GCP; con `client` puedes filtrar costos por cliente |
| `delete_contents_on_destroy` | CI: `true` (son de prueba). Prod: `false` → Terraform se niega a borrar un dataset con datos |
| `depends_on` | "Primero las APIs". No hay referencia directa entre ambos recursos, así que el orden se declara |

`trendy_dev_*` no está aquí a propósito: los crea dbt en tu máquina. Es tu espacio de desarrollo, no infraestructura compartida.

### 7A.6 · Inicializar, explorar y aplicar

```powershell
terraform init
terraform fmt
terraform validate
terraform console
```

En la consola, evalúa una por una (y `exit` para salir):

```
local.envs
keys(local.envs)
setproduct(keys(local.envs), local.layers)
local.datasets
local.datasets["prod_gold"].dataset_id
```

`terraform console` evalúa expresiones sin crear nada: la mejor forma de entender una expresión compleja es desarmarla.

```powershell
terraform plan -out=tfplan
terraform apply tfplan
terraform state list
```

### ✅ Checkpoint Etapa 7A

- `Plan: 7 to add, 0 to change, 0 to destroy` (1 API + 6 datasets), con `dataset_id` `trendy_*` y `trendy_ci_*`.
- Los 6 datasets aparecen en la consola de BigQuery.
- (Si hiciste el bootstrap primero) `gcloud storage objects describe gs://emra-co-tfstate/trendy/default.tfstate --impersonate-service-account=$SA` ahora funciona.

```powershell
cd ..
git add .
git status   # versions.tf, variables.tf, apis.tf, bigquery.tf, .terraform.lock.hcl; NO terraform.tfvars ni tfplan
git commit -m "Etapa 7A: Terraform base y datasets de BigQuery"
```

---

## Etapa 7B · Service accounts y permisos

**Objetivo:** definir **quién** puede usar cada dataset, con mínimo privilegio.

**Dos niveles de permisos en BigQuery** (hacen falta los dos):

| Rol | Nivel | Permite |
|---|---|---|
| `roles/bigquery.jobUser` | Proyecto | *Ejecutar* consultas ("jobs"). No da acceso a datos |
| `roles/bigquery.dataEditor` | Dataset | Leer, crear y modificar tablas **en ese dataset** |

Es como la **licencia de conducir** (jobUser) y **las llaves de un auto específico** (dataEditor).

### 7B.1 · APIs

En `apis.tf`:

```hcl
  apis = [
    "bigquery.googleapis.com",
    "iam.googleapis.com",
  ]
```

### 7B.2 · `terraform/iam.tf`

```hcl
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
```

| Concepto | Ejemplo | Significado |
|---|---|---|
| Referencia entre recursos | `google_service_account.runner.member` | Vale `"serviceAccount:trendy-runner@…"`, y Terraform deduce el orden solo (primero la SA) |
| Filtrar un mapa | `{ for k, v in local.datasets : k => v if v.env == "prod" }` | Se queda con los 3 de prod |
| Acceder a un `for_each` | `google_bigquery_dataset.dbt[each.key]` | Con `"prod_gold"` se refiere a `trendy_gold` |

**`_iam_member`, nunca `_iam_binding` ni `_iam_policy`** en un proyecto compartido:

| Recurso | Qué hace | En un proyecto compartido |
|---|---|---|
| `*_iam_member` | **Agrega** un permiso a una cuenta | ✅ Seguro |
| `*_iam_binding` | Define la **lista completa** de cuentas con ese rol | ❌ Le quita el rol a las cuentas de otros proyectos |
| `*_iam_policy` | Define **todos** los permisos del recurso | ❌❌ Borra todo lo demás, incluso tu acceso de owner |

### 7B.3 · Aplicar

```powershell
cd terraform
terraform fmt
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
gcloud iam service-accounts list --project emra-co --filter="email:trendy-*"
```

### ✅ Checkpoint Etapa 7B

- `Plan: 12 to add` = 1 API + 3 SAs + 2 `jobUser` + 3 `dataEditor` de prod + 3 de ci. Los recursos de la 7A **no** aparecen: ya existen tal cual.
- En BigQuery → `trendy_gold` → Compartir → Permisos: `trendy-runner` como Data Editor. En `trendy_ci_gold`: `trendy-deployer`, **no** `trendy-runner`.

```powershell
cd ..
git add .
git commit -m "Etapa 7B: service accounts y permisos de BigQuery"
```

---

## Etapa 7C · Dónde y cuándo corre dbt

**Objetivo:** Artifact Registry, el Cloud Run Job y el Scheduler.

```
Artifact Registry          Cloud Run Job              Cloud Scheduler
(guarda la imagen)   ──►   (la ejecuta como       ◄── (lo dispara cada día
                            trendy-runner)              como trendy-scheduler)
```

### 7C.1 · APIs y variables

`apis.tf`:

```hcl
  apis = [
    "bigquery.googleapis.com",
    "iam.googleapis.com",
    "artifactregistry.googleapis.com",
    "run.googleapis.com",
    "cloudscheduler.googleapis.com",
  ]
```

Al final de `variables.tf`:

```hcl
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
```

**Formato cron** (5 campos):

```
┌──── minuto       (0)
│ ┌── hora         (6)
│ │ ┌ día del mes  (* = todos)
│ │ │ ┌ mes        (* = todos)
│ │ │ │ ┌ día de la semana (* = todos)
0 6 * * *    →  todos los días a las 6:00
```

Otros: `0 6 * * 1-5` (lunes a viernes a las 6:00), `0 */4 * * *` (cada 4 horas). La zona horaria importa: `America/Bogota` es UTC-5 y `America/Costa_Rica` es UTC-6.

### 7C.2 · `terraform/artifact_registry.tf`

```hcl
# Aquí GitHub sube las imágenes Docker de dbt
resource "google_artifact_registry_repository" "dbt" {
  repository_id = var.prefix
  location      = var.region
  format        = "DOCKER"
  description   = "Imágenes del job de dbt de ${var.prefix}"

  # Cada deploy sube una imagen nueva: conservamos solo las 10 más recientes
  cleanup_policies {
    id     = "keep-last-10"
    action = "KEEP"
    most_recent_versions {
      keep_count = 10
    }
  }

  depends_on = [google_project_service.apis]
}

# El deployer (GitHub) puede subir imágenes, solo a ESTE repositorio
resource "google_artifact_registry_repository_iam_member" "deployer_writer" {
  location   = google_artifact_registry_repository.dbt.location
  repository = google_artifact_registry_repository.dbt.name
  role       = "roles/artifactregistry.writer"
  member     = google_service_account.deployer.member
}
```

- Artifact Registry es el "Docker Hub privado" de GCP. La imagen queda en `us-central1-docker.pkg.dev/emra-co/trendy/dbt:<commit>`.
- **`cleanup_policies`:** cada merge sube una imagen de ~500 MB; sin limpieza pagarías por cientos de imágenes.
- **`writer`, no `admin`:** el deployer sube imágenes, pero no borra ni reconfigura el repo.

### 7C.3 · `terraform/cloud_run.tf`

```hcl
resource "google_cloud_run_v2_job" "dbt" {
  name                = "${var.prefix}-dbt"
  location            = var.region
  deletion_protection = false

  template {
    task_count = 1

    template {
      service_account = google_service_account.runner.email
      timeout         = "1800s"
      max_retries     = 1

      containers {
        # Imagen de prueba de Google. GitHub la reemplaza en cada deploy.
        image = "us-docker.pkg.dev/cloudrun/container/job:latest"

        # profiles.yml (target prod) lee estas variables
        env {
          name  = "GCP_PROJECT"
          value = var.project_id
        }
        env {
          name  = "DBT_DATASET"
          value = var.prefix
        }

        resources {
          limits = {
            cpu    = "1"
            memory = "1Gi"
          }
        }
      }
    }
  }

  # La imagen la maneja el pipeline de deploy, no Terraform
  lifecycle {
    ignore_changes = [
      template[0].template[0].containers[0].image,
      client,
      client_version,
    ]
  }

  depends_on = [google_project_service.apis]
}

# Scheduler puede ejecutar ESTE job
resource "google_cloud_run_v2_job_iam_member" "scheduler_invoker" {
  location = google_cloud_run_v2_job.dbt.location
  name     = google_cloud_run_v2_job.dbt.name
  role     = "roles/run.invoker"
  member   = google_service_account.scheduler.member
}

# El deployer (GitHub) puede actualizar la imagen de ESTE job
resource "google_cloud_run_v2_job_iam_member" "deployer_developer" {
  location = google_cloud_run_v2_job.dbt.location
  name     = google_cloud_run_v2_job.dbt.name
  role     = "roles/run.developer"
  member   = google_service_account.deployer.member
}
```

**Los dos `template` anidados:**

| Nivel | Configura |
|---|---|
| `template` externo | La **ejecución**: cuántas tareas en paralelo (`task_count`); dbt es una |
| `template` interno | **Cada tarea**: contenedor, SA, timeout, reintentos |

| Línea | Por qué |
|---|---|
| `service_account = ...runner.email` | El contenedor corre **como `trendy-runner`**: por eso dbt puede escribir en `trendy_*` y no en otros datasets |
| `env DBT_DATASET = var.prefix` | Conecta con `profiles.yml` (target prod): el nombre se define en un solo lugar |
| `timeout = "1800s"` | Cloud Run detiene dbt a los 30 minutos |
| `max_retries = 1` | Si falla, reintenta una vez (útil contra errores de red) |
| `image = ".../job:latest"` | Imagen de prueba de Google: permite crear el job antes de tener tu imagen |

**`ignore_changes`: dos dueños para un mismo recurso.**

```
Terraform es dueño de:     la SA, las variables, el CPU, el timeout...
GitHub es dueño de:        la IMAGEN (la cambia en cada deploy)
```

Sin `ignore_changes`, el siguiente `apply` después de un deploy volvería a poner la imagen de prueba, y producción quedaría corriendo un "hola mundo". `client` y `client_version` son metadatos que escribe `gcloud` al actualizar el job.

**Permisos sobre el job, no sobre el proyecto:** `trendy-scheduler` solo puede **ejecutar** este job; `trendy-deployer` solo puede actualizar **este** job.

### 7C.4 · Dos permisos más en `iam.tf`

Al final de `iam.tf`:

```hcl
# ---------------------------------------------------------- Deployer (deploy)

# Para actualizar un job que corre como trendy-runner, hay que poder "actuar como" ella
resource "google_service_account_iam_member" "deployer_acts_as_runner" {
  service_account_id = google_service_account.runner.name
  role               = "roles/iam.serviceAccountUser"
  member             = google_service_account.deployer.member
}

# Solo lectura de Cloud Run: gcloud la necesita para seguir el progreso del deploy
resource "google_project_iam_member" "deployer_run_viewer" {
  project = var.project_id
  role    = "roles/run.viewer"
  member  = google_service_account.deployer.member
}
```

**¿Por qué "actuar como" el runner?** Si pudieras desplegar un job que corre como `trendy-runner` sin permiso sobre `trendy-runner`, podrías robarle sus permisos con un contenedor tuyo. GCP exige `serviceAccountUser` sobre la SA con la que corre el job. Por el mismo motivo `trendy-terraform` tiene ese rol: **crea** ese job.

### 7C.5 · `terraform/scheduler.tf`

```hcl
resource "google_cloud_scheduler_job" "dbt_daily" {
  name             = "${var.prefix}-dbt-daily"
  region           = var.region
  schedule         = var.schedule
  time_zone        = var.time_zone
  attempt_deadline = "320s"

  retry_config {
    retry_count = 1
  }

  # Llama a la API de Cloud Run: "ejecuta este job"
  http_target {
    http_method = "POST"
    uri         = "https://run.googleapis.com/v2/projects/${var.project_id}/locations/${var.region}/jobs/${google_cloud_run_v2_job.dbt.name}:run"

    oauth_token {
      service_account_email = google_service_account.scheduler.email
    }
  }

  depends_on = [google_cloud_run_v2_job_iam_member.scheduler_invoker]
}
```

Cloud Scheduler no "sabe" de Cloud Run: hace **llamadas HTTP** a la hora programada. Aquí llama a `POST .../jobs/trendy-dbt:run`, lo mismo que hace `gcloud run jobs execute`.

| Parte | Qué hace |
|---|---|
| `oauth_token` | Firma la llamada como `trendy-scheduler`; Cloud Run verifica que tenga `run.invoker` |
| `attempt_deadline = "320s"` | Cuánto espera la **respuesta de la API** (segundos), no lo que tarda dbt |
| `retry_config` | Si la API falla al iniciar el job, reintenta una vez |
| `depends_on` | Crea el permiso antes que el scheduler |

### 7C.6 · Aplicar

```powershell
cd terraform
terraform fmt
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
```

Tarda 2–3 minutos porque activa APIs. Si aparece *API … has not been used / is disabled*, espera un minuto y repite. Si aparece `403` o `Permission denied`, le falta un rol a `trendy-terraform`: el error dice qué permiso; agrégalo en `bootstrap/clients.tf`.

### 7C.7 · 🔍 Probar la cadena completa con la imagen de prueba

```powershell
gcloud run jobs execute trendy-dbt --region us-central1 --project emra-co --wait
gcloud scheduler jobs run trendy-dbt-daily --location us-central1 --project emra-co
gcloud run jobs executions list --job trendy-dbt --region us-central1 --project emra-co
```

| Símbolo en `executions list` | Significa |
|---|---|
| `.` | En curso o pendiente (espera un minuto antes de preocuparte) |
| `+` | Terminó bien |
| `X` | Falló |

Busca quién creó los recursos en los logs de auditoría:

```powershell
gcloud logging read "protoPayload.authenticationInfo.principalEmail=\"trendy-terraform@emra-co.iam.gserviceaccount.com\"" --project emra-co --freshness=1h --limit=15 --format="table(timestamp,protoPayload.methodName)"
```

### ✅ Checkpoint Etapa 7C

- `Plan: 11 to add` = 3 APIs + repo + writer + job + invoker + developer + actAs + run.viewer + scheduler.
- Dos ejecuciones con `+`: una **RUN BY** tu correo y otra **RUN BY** `trendy-scheduler@…`.
- En los logs aparecen `CreateJob` y `CreateRepository` hechos por `trendy-terraform`, no por tu cuenta.

```powershell
cd ..
git add .
git commit -m "Etapa 7C: Artifact Registry, Cloud Run Job y Scheduler"
```

---

## Etapa 7D · GitHub sin llaves

**Objetivo:** que GitHub Actions entre a GCP como `trendy-deployer` sin guardar ninguna contraseña.

**La forma antigua (insegura):** descargar una llave JSON y guardarla como secreto en GitHub. No expira, sirve desde cualquier computador si se filtra y nadie la rota.

**Workload Identity Federation:**

```
1. GitHub Actions corre un workflow de emrangel/gcp_dbt_model
2. GitHub le entrega un TOKEN firmado (OIDC): "soy un workflow del repo emrangel/gcp_dbt_model"  (~5 min)
3. GCP (STS) verifica la firma con las llaves públicas de GitHub y revisa tu condición
4. GCP entrega un token temporal de trendy-deployer (1 hora)
```

| Recurso | Analogía | Qué es |
|---|---|---|
| **Pool** | El edificio | Agrupa identidades externas aceptadas |
| **Provider** | La recepción | Confía en tokens de GitHub y aplica tu condición |
| **Binding** | La llave del piso | Quien pasó la recepción puede actuar como `trendy-deployer` |

### 7D.1 · API, variable y tfvars

En `apis.tf`, agrega `"sts.googleapis.com",` al final de la lista (STS cambia el token de GitHub por uno de GCP).

Al final de `variables.tf`:

```hcl
variable "github_repo" {
  description = "Único repo que puede desplegar, formato owner/repo."
  type        = string
}
```

`terraform.tfvars`:

```hcl
project_id  = "emra-co"
prefix      = "trendy"
github_repo = "emrangel/gcp_dbt_model"
```

El repo todavía no tiene que existir en GitHub: aquí solo le dices a GCP a quién aceptar. Créalo después **con ese nombre exacto**.

### 7D.2 · `terraform/workload_identity.tf`

```hcl
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
```

El token que envía GitHub (simplificado):

```json
{
  "iss": "https://token.actions.githubusercontent.com",
  "sub": "repo:emrangel/gcp_dbt_model:ref:refs/heads/main",
  "repository": "emrangel/gcp_dbt_model",
  "ref": "refs/heads/main",
  "event_name": "push",
  "actor": "emrangel"
}
```

| Parte | Qué hace |
|---|---|
| `oidc.issuer_uri` | Confía en tokens firmados por GitHub Actions |
| `attribute_mapping` | Copia campos del token (`assertion.*`) a atributos de GCP; `google.subject` es obligatorio |
| `attribute_condition` | **El filtro:** un token de otro repo se rechaza aunque esté bien firmado |
| `principalSet://…/attribute.repository/<repo>` | No es una persona ni una SA: es **cualquier workflow de ese repo** |

Tu repo aparece **dos veces** (condición y binding): defensa en dos capas.

> ⚠️ Un pool borrado reserva su ID unos 30 días: no experimentes creando y borrando pools.
> ⚠️ GitHub permite renombrar repos: la protección completa es filtrar por `repository_id` (ver [Pendientes](#pendientes)).

### 7D.3 · `terraform/outputs.tf`

```hcl
# Copia estos valores en GitHub → Settings → Secrets and variables → Actions → Variables
output "github_variables" {
  description = "Variables que usan los workflows de GitHub Actions."
  value = {
    GCP_PROJECT    = var.project_id
    GCP_REGION     = var.region
    WIF_PROVIDER   = google_iam_workload_identity_pool_provider.github.name
    DEPLOYER_SA    = google_service_account.deployer.email
    AR_REPO        = google_artifact_registry_repository.dbt.repository_id
    JOB_NAME       = google_cloud_run_v2_job.dbt.name
    DBT_CI_DATASET = "${var.prefix}_ci"
  }
}
```

Un `output` no crea nada: es Terraform informando valores calculados. `WIF_PROVIDER` solo se conoce después de crear el provider, porque incluye el **número** del proyecto.

### 7D.4 · Aplicar y verificar

```powershell
cd terraform
terraform fmt
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
terraform output github_variables
gcloud iam workload-identity-pools providers describe github --workload-identity-pool=trendy-github --location=global --project=emra-co --format="value(state,attributeCondition)"
```

### ✅ Checkpoint Etapa 7D

- `Plan: 4 to add` (1 API + pool + provider + binding) y `Changes to Outputs`.
- El provider en `ACTIVE` con `assertion.repository == "emrangel/gcp_dbt_model"`.
- `terraform state list` muestra **34 recursos** en Trendy.
- La prueba real ocurre en el primer PR (Etapa 8).

```powershell
cd ..
git add .
git status   # apis.tf, variables.tf, workload_identity.tf, outputs.tf; NO terraform.tfvars
git commit -m "Etapa 7D: Workload Identity para GitHub y outputs"
```

---

## Parte V · GitHub y despliegue

## Etapa 8 · CI/CD

**Objetivo:** subir el código y que el primer PR pruebe Workload Identity de verdad.

### 8.1 · Target `ci` en `profiles.yml`

Dentro de `outputs:`:

```yaml
    ci:
      type: bigquery
      method: oauth
      project: "{{ env_var('GCP_PROJECT', 'emra-co') }}"
      dataset: "{{ env_var('DBT_CI_DATASET', 'trendy_ci') }}"
      location: US
      threads: 4
      maximum_bytes_billed: 1000000000
```

| | dev | ci | prod |
|---|---|---|---|
| Quién | Tú | GitHub, en cada PR | Cloud Run, a diario |
| Datasets | `trendy_dev_*` | `trendy_ci_*` | `trendy_*` |
| Identidad | Tu cuenta | `trendy-deployer` | `trendy-runner` |
| Freno de 1 GB | ✅ | ✅ | ❌ |

`method: oauth` funciona en los tres: dbt usa las credenciales del entorno. En GitHub las pone el paso `auth` del workflow.

```powershell
uv run dbt debug --target ci
git add profiles.yml
git commit -m "Etapa 8: target ci en profiles.yml"
```

### 8.2 · Crear el repo y subir el código

En [github.com/new](https://github.com/new), con tu cuenta:
- **Repository name:** `gcp_dbt_model` (exactamente el de la condición de Workload Identity).
- **Public** (en planes gratuitos, los "Required reviewers" de environments solo existen en repos públicos).
- **Sin** README, `.gitignore` ni license.

```powershell
git remote add origin git@github-personal:emrangel/gcp_dbt_model.git
git remote -v
git push -u origin main
```

Sin `.github/workflows/` todavía, el push **no dispara nada**. El `-u` enlaza tu rama local con la de GitHub; después basta `git push`.

### 8.3 · Variables de GitHub

**Settings → Secrets and variables → Actions → pestaña Variables → New repository variable.** Crea las 7 de `terraform output github_variables`:

| Name | Value |
|---|---|
| `GCP_PROJECT` | `emra-co` |
| `GCP_REGION` | `us-central1` |
| `WIF_PROVIDER` | `projects/1052961859131/locations/global/workloadIdentityPools/trendy-github/providers/github` |
| `DEPLOYER_SA` | `trendy-deployer@emra-co.iam.gserviceaccount.com` |
| `AR_REPO` | `trendy` |
| `JOB_NAME` | `trendy-dbt` |
| `DBT_CI_DATASET` | `trendy_ci` |

> ⚠️ **Trampa:** tienen que ir en la pestaña **Variables**, sección **Repository variables**. Ni en **Secrets** (los workflows leen `vars.X`, no `secrets.X`) ni en las variables del environment `production` (el job de CI no declara ese environment y no las vería).

| | Secrets | Variables |
|---|---|---|
| Para | Contraseñas, API keys, tokens | Configuración no sensible |
| ¿Se pueden leer después? | No | Sí |
| En los logs | Se ocultan como `***` | Se ven |
| En el workflow | `${{ secrets.X }}` | `${{ vars.X }}` |
| En este proyecto | **Ninguno** | Las 7 |

### 8.4 · (Opcional) Aprobación de deploys

**Settings → Environments → New environment** `production` → **Required reviewers** → agrégate → **no** marques "Prevent self-review" (si eres el único, bloquearía tus deploys) → **Save protection rules**.

### 8.5 · Los workflows, en una rama

Van en un PR para que el **primer PR pruebe el propio CI**: si algo falla, falla antes de llegar a `main`.

```powershell
git checkout -b ci/workflows
mkdir .github\workflows
```

**`.github/workflows/ci.yml`**

```yaml
name: ci

# En cada PR: dbt contra los datasets de CI y Terraform validado
on:
  pull_request:

permissions:
  contents: read
  id-token: write   # para pedirle a GitHub el token de Workload Identity

concurrency:
  group: dbt-ci     # los PR comparten trendy_ci_*: uno a la vez
  cancel-in-progress: false

jobs:
  dbt:
    runs-on: ubuntu-latest
    env:
      GCP_PROJECT: ${{ vars.GCP_PROJECT }}
      DBT_CI_DATASET: ${{ vars.DBT_CI_DATASET }}
    steps:
      - uses: actions/checkout@v4

      - uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: ${{ vars.WIF_PROVIDER }}
          service_account: ${{ vars.DEPLOYER_SA }}

      - uses: astral-sh/setup-uv@v6
        with:
          version: "0.13.0"
          enable-cache: true

      - run: uv sync --locked
      - run: uv run dbt deps
      - run: uv run dbt build --target ci

  terraform:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        dir: [terraform, terraform/bootstrap]
    defaults:
      run:
        working-directory: ${{ matrix.dir }}
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
      - run: terraform fmt -check
      - run: terraform init -backend=false
      - run: terraform validate
```

| Bloque | Significado |
|---|---|
| `on: pull_request` | Corre al abrir un PR y en cada push a ese PR |
| `permissions: id-token: write` | **Imprescindible:** sin esto GitHub no entrega el token OIDC |
| `concurrency` | Dos PRs a la vez esperan su turno: ambos escriben en `trendy_ci_*` |
| `jobs` | Corren en paralelo, cada uno en una máquina limpia (`ubuntu-latest`) |
| `steps` | Corren en orden dentro del job |
| `uses:` / `run:` | Una acción hecha por otros / un comando de terminal |
| `${{ vars.X }}` | Las variables del paso 8.3 |

- **Job `dbt`:** `checkout` descarga el código; `google-github-actions/auth` hace **todo Workload Identity** (pide el token, lo cambia en STS y suplanta a `trendy-deployer`); `setup-uv` instala la misma versión de uv; y luego los mismos comandos de tu máquina con `--target ci`.
- **Job `terraform` con `matrix`:** se repite una vez por cada carpeta, en paralelo. `fmt -check` falla si el código no está formateado (no lo arregla); `init -backend=false` descarga el proveedor sin conectarse al bucket (este job no tiene credenciales y no las necesita); `validate` revisa sintaxis y referencias. **No aplica nada.**

**`.github/workflows/deploy.yml`**

```yaml
name: deploy

# Despliega una imagen nueva del job:
#   - automáticamente al hacer merge a main
#   - o a mano desde Actions → deploy → "Run workflow"
on:
  push:
    branches: [main]
    paths-ignore:
      - "terraform/**"
      - "**.md"
  workflow_dispatch:
    inputs:
      run_now:
        description: "Ejecutar el job apenas termine el deploy"
        type: boolean
        default: false

permissions:
  contents: read
  id-token: write

concurrency:
  group: dbt-deploy
  cancel-in-progress: false

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: production
    env:
      IMAGE: ${{ vars.GCP_REGION }}-docker.pkg.dev/${{ vars.GCP_PROJECT }}/${{ vars.AR_REPO }}/dbt:${{ github.sha }}
    steps:
      - uses: actions/checkout@v4

      - uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: ${{ vars.WIF_PROVIDER }}
          service_account: ${{ vars.DEPLOYER_SA }}

      - uses: google-github-actions/setup-gcloud@v2

      - name: Construir y subir la imagen
        run: |
          gcloud auth configure-docker ${{ vars.GCP_REGION }}-docker.pkg.dev --quiet
          docker build -t "$IMAGE" .
          docker push "$IMAGE"

      - name: Actualizar el Cloud Run Job
        run: |
          gcloud run jobs update ${{ vars.JOB_NAME }} \
            --image "$IMAGE" \
            --region ${{ vars.GCP_REGION }} \
            --project ${{ vars.GCP_PROJECT }}

      - name: Ejecutar ahora
        if: ${{ inputs.run_now }}
        run: |
          gcloud run jobs execute ${{ vars.JOB_NAME }} \
            --region ${{ vars.GCP_REGION }} \
            --project ${{ vars.GCP_PROJECT }} \
            --wait
```

| Parte | Qué hace |
|---|---|
| `on: push: branches: [main]` | Corre al hacer merge, no en los PRs |
| `paths-ignore` | No despliega si **solo** cambió Terraform o archivos `.md` (la imagen no cambiaría) |
| `workflow_dispatch` + `run_now` | Botón **Run workflow** con una casilla para ejecutar el job al final |
| `environment: production` | Si configuraste revisor, el deploy espera tu aprobación |
| `IMAGE: …:${{ github.sha }}` | La imagen se etiqueta con el hash del commit: sabes exactamente qué código corre y puedes volver atrás |
| `if: ${{ inputs.run_now }}` | Ese paso solo corre si marcaste la casilla |

| Paso del deploy | Permiso de `trendy-deployer` | Etapa |
|---|---|---|
| `docker push` | `artifactregistry.writer` sobre el repo | 7C |
| `gcloud run jobs update` | `run.developer` sobre el job + `serviceAccountUser` sobre el runner | 7C |
| Seguir el progreso | `run.viewer` en el proyecto | 7C |

### 8.6 · Commit, push y PR

```powershell
git add .github
git commit -m "Etapa 8: workflows de CI y deploy"
git push -u origin ci/workflows
```

En GitHub: **Compare & pull request** → base `main` ← compare `ci/workflows` → **Create pull request**.

### ✅ Checkpoint Etapa 8

Tres checks en verde:

| Check | Prueba | Tiempo |
|---|---|---|
| `ci / dbt` | **Workload Identity de verdad** y que `trendy-deployer` escribe en `trendy_ci_*` | ~1–2 min |
| `ci / terraform (terraform)` | Formato y sintaxis de Trendy | ~30 s |
| `ci / terraform (terraform/bootstrap)` | Formato y sintaxis de bootstrap | ~30 s |

Y en BigQuery: `trendy_ci_gold.fct_campaign_performance` con 4 filas, mientras `trendy_bronze` y `trendy_gold` siguen **vacíos** (un PR no puede tocar producción).

Si un check falla, abre **Details** → el paso en rojo. Para reintentar después de corregir variables: **Re-run jobs → Re-run failed jobs** (no hace falta otro commit).

| Error | Causa probable |
|---|---|
| `must specify exactly one of "workload_identity_provider"` | Variables en Secrets o en el environment |
| `unauthorized_client` / `attribute condition` | El nombre del repo no coincide exactamente |
| `getAccessToken denied` | El binding `principalSet` no coincide con el repo |
| `fmt -check` muestra un archivo | Falta correr `terraform fmt` en esa carpeta |
| `Access Denied` en `dbt build` | Falta un permiso de `trendy-deployer` en BigQuery |

**No hagas merge todavía.**

---

## Etapa 9 · Primer deploy

**Objetivo:** merge, imagen real en Cloud Run y primera ejecución en producción.

### 9.1 · Merge

En el PR: **Merge pull request → Confirm merge** → borra la rama `ci/workflows`.

El merge es un push a `main` que cambió `.github/workflows/` (ni `.md` ni `terraform/`), así que dispara **deploy**. Con revisor configurado: **Review deployments → production → Approve and deploy**.

### 9.2 · Seguir el deploy

**Actions → deploy → job deploy:**

| Paso | Qué pasa | Tiempo |
|---|---|---|
| `auth` | Workload Identity, igual que en CI | segundos |
| Construir y subir la imagen | Tu Dockerfile: Python, uv, `uv sync`, `dbt deps` | 2–4 min la primera vez |
| Actualizar el Cloud Run Job | Cambia la imagen de prueba por la tuya | ~20 s |
| Ejecutar ahora | ⏭️ **Omitido**: el merge no tiene `run_now` | — |

### 9.3 · Verificar la imagen y `ignore_changes`

```powershell
gcloud run jobs describe trendy-dbt --region us-central1 --project emra-co --format="value(spec.template.spec.template.spec.containers[0].image)"
git ls-remote origin main
cd terraform
terraform plan
cd ..
```

- La imagen termina en el **mismo hash** que `main` en GitHub.
- `terraform plan` dice **`No changes`**: GitHub cambió la imagen y Terraform no la reclama.

### 9.4 · 🚀 Primera ejecución en producción

**Actions → deploy → Run workflow** → rama `main` → **✅ marca `run_now`** → **Run workflow** (y apruébalo si hay revisor).

### 9.5 · Verificar producción

```powershell
gcloud run jobs executions list --job trendy-dbt --region us-central1 --project emra-co
gcloud logging read "resource.type=\"cloud_run_job\" AND resource.labels.job_name=\"trendy-dbt\" AND textPayload:\"Done.\"" --project emra-co --freshness=1h --limit=1 --format="value(textPayload)"
```

### ✅ Checkpoint Etapa 9

- La ejecución más reciente tiene `+`, `1 / 1` y **RUN BY** `trendy-deployer@…`.
- Los logs dicen `Done. PASS=11 WARN=0 ERROR=0 SKIP=0 … TOTAL=11`.
- `trendy_gold.fct_campaign_performance` tiene 4 filas; la campaña 2001 coincide con tu cálculo de la Etapa 5.

```powershell
git checkout main
git pull
```

🎉 **El pipeline está en producción.** Desde aquí, el Scheduler lo ejecuta solo todos los días.

---

## Parte VI · Operación diaria

### Cambiar SQL

```powershell
git checkout -b feat/mi-cambio
# editas models/...
uv run dbt build --select +mi_modelo+     # el modelo, lo que depende de él y lo que él necesita
git add .
git commit -m "Describe el cambio"
git push -u origin feat/mi-cambio
```

PR → `ci` en verde → merge → `deploy` construye la imagen. Corre al día siguiente a las 6:00, o a mano con `run_now`.

### Cambiar infraestructura

```powershell
cd terraform
# editas *.tf
terraform fmt
terraform plan -out=tfplan      # revisa: ¿destruye algo?
terraform apply tfplan
```

Y luego un PR con los `.tf` (el CI valida formato y sintaxis). Un PR que solo cambia `terraform/` o `.md` **no** dispara deploy.

### Ejecutar fuera de horario

```powershell
gcloud run jobs execute trendy-dbt --region us-central1 --project emra-co --wait
```

Solo un modelo, sin construir otra imagen (reemplaza el `CMD`):

```powershell
gcloud run jobs execute trendy-dbt --region us-central1 --project emra-co --args="build,--select,fct_campaign_performance,--target,prod"
```

### Ver qué pasó

- **Ejecuciones:** `gcloud run jobs executions list --job trendy-dbt --region us-central1 --project emra-co`
- **Consola:** Cloud Run → Jobs → `trendy-dbt` → Executions → Logs.
- **Quién hizo qué:** los logs de auditoría (`protoPayload.authenticationInfo.principalEmail`).

### Cambiar de cuenta

```powershell
gcloud config configurations activate trabajo
gcloud auth application-default login
```

Recuerda: las ADC son una sola; repite el `application-default login` al volver.

### Agregar un cliente nuevo (por ejemplo, `acme`)

1. En `terraform/bootstrap/variables.tf`: `clients = ["trendy", "acme"]` → `terraform apply` en `bootstrap/`.
2. Copia el proyecto, y en el nuevo `terraform/versions.tf` cambia el `prefix` del backend a `acme` y la SA a `acme-terraform@…`.
3. `terraform.tfvars` con `prefix = "acme"` y su repo.
4. En dbt: `name`/`profile` y los datasets de `profiles.yml`.

---

## Parte VII · Referencia

## Errores comunes

### Cómo distinguir el tipo de error

| Si el error dice… | Es un problema de… | Qué hacer |
|---|---|---|
| `NameResolutionError`, `getaddrinfo`, `no such host`, `ConnectionError`, `timed out` | **Red** | Esperar y reintentar |
| `Syntax error`, `Unrecognized name`, `Column not found` | **Tu SQL** | Revisar el modelo |
| `Access Denied`, `Permission`, `403` | **Permisos** | Revisar la cuenta y los roles |
| `FAIL 1 … Got 1 result` | **Un test**: los datos no cumplen una regla | Revisar los datos o la regla |

### Los que encontramos

| Mensaje | Causa | Solución |
|---|---|---|
| `no such host`, `NameResolutionError`, `getaddrinfo failed` | DNS intermitente de la red corporativa | Reintentar; `ipconfig /flushdns` o reconectar la VPN |
| `invalid peer certificate: UnknownIssuer` | El proxy intercepta HTTPS | `setx UV_SYSTEM_CERTS 1` |
| `The filename, directory name, or volume label syntax is incorrect` | `$env:` en CMD | PowerShell, o `set VAR=valor` |
| `uv : The term 'uv' is not recognized` | VS Code abierto antes de instalar uv | Cerrar VS Code por completo |
| `Invalid value for '--profiles-dir': Path '...\.dbt' does not exist` | dbt no encuentra `profiles.yml` | Ponlo en la raíz, o define `DBT_PROFILES_DIR` |
| `Reauthentication failed. cannot prompt during non-interactive execution` | Sesión de gcloud vencida | `gcloud auth login` y `gcloud auth application-default login` |
| `Cannot rename configuration [default], it is the currently active configuration` | Se intentó renombrar el perfil activo | Activa otro perfil primero |
| `'origin' does not appear to be a git repository` | Faltó `git remote add` | `git remote add origin git@github-personal:USUARIO/REPO.git` |
| `must specify exactly one of "workload_identity_provider" or "credentials_json"` | Variables en Secrets o en el environment | Moverlas a Repository variables |
| `Planning failed … Error when reading or editing …: no such host` | DNS | Reintentar el plan |
| Apply a medias con un recurso fallido | Red o API recién activada | `plan -out` y `apply` otra vez |
| Recursos escritos y en el commit, pero no existen en GCP | Faltó el `apply` | Solo `apply` crea cosas |
| El deploy terminó y no hay ejecuciones | No se marcó `run_now` | Relanzar con la casilla, o `gcloud run jobs execute` |
| `executions list` muestra `.` y `0 / 1` | La ejecución sigue en curso | Esperar un minuto |
| Terraform falla con *already exists* | Nombres repetidos en un proyecto compartido, o datasets creados por dbt en prod | Usar otro `prefix`; no correr `dbt build --target prod` en local |

---

## Preguntas que surgieron

### ¿`dbt build` crea las tablas de verdad?

Sí. dbt no guarda datos: **traduce tu SQL y se lo manda a BigQuery**. Tú escribes solo el `SELECT`; dbt agrega el resto según la materialización:

```
Tu .sql (SELECT + Jinja) ─► dbt compila ({{ ref() }} → nombres reales) ─► lo envuelve ─► BigQuery lo ejecuta
```

- Seed → un **load job** (carga de archivo).
- Silver (`view`) → `create or replace view … as (…)`.
- Gold (`table`) → `create or replace table … as (…)`.
- Tests → `select` que buscan filas malas; no crean nada.

Por el `create or replace`, correrlo dos veces **reemplaza**, no duplica. Para ver el SQL sin ejecutar nada: `uv run dbt compile` (queda en `target/compiled/`); lo que se ejecutó de verdad queda en `target/run/`.

### ¿Por qué Terraform no crea el bucket del state?

Porque lo necesita **antes** de empezar: `terraform init` lee el state del bucket, y el bucket lo crearía `apply`, que va después. La solución es una capa aparte (bootstrap) que empieza con state local y luego lo mueve al bucket (`-migrate-state`). La misma lógica aplica a la API Cloud Resource Manager, que se activa a mano con `gcloud`.

### ¿Por qué tantos datasets?

Son **3 entornos × 3 capas = 9**.
- **Entornos separados** para que nadie pise lo que ve el dashboard, y porque en BigQuery **los permisos se asignan por dataset**: así `trendy-deployer` puede escribir en CI y no en prod.
- **Capas separadas** para dar acceso por consumidor (los analistas solo ven gold), ordenar y aplicar políticas distintas (por ejemplo, expiración en bronze).
- BigQuery no cobra por dataset. Una alternativa con menos datasets es uno por entorno con las capas como prefijo de tabla, a costa de no poder dar acceso solo a gold.

### ¿Quién debería correr `terraform apply` en un equipo?

**Una service account, a través de un pipeline**, después de que alguien revise el plan en un PR. Las personas no aplican a mano en producción:

```
Escribes .tf → PR → CI corre "plan" y lo publica → revisión → merge → CI corre "apply" como <cliente>-terraform
```

| Quién | Rol típico | Puede |
|---|---|---|
| Desarrolladores | `viewer` + `iam.securityReviewer` + lectura del bucket de state + BigQuery en dev | Leer todo, correr `plan`, trabajar en dev |
| SA de plan (PRs) | Igual que los desarrolladores | Calcular planes |
| SA de apply (`main`) | Los roles específicos del bootstrap | Crear y modificar |
| Equipo de plataforma | Admin de organización/carpetas | Proyectos, red, políticas |
| Break-glass | Owner, con alertas | Solo emergencias |

**No Owner**, porque lo permite todo y Google desaconseja los roles básicos en producción. En un proyecto personal, ser owner y aplicar desde tu máquina está bien (además, un proyecto fuera de una organización debe tener al menos un owner). El punto intermedio, que usa este repo, es **suplantar** a la SA de Terraform: tú corres `apply`, pero GCP ve a `trendy-terraform` y sus permisos limitados.

### ¿Una SA de Terraform para todo o una por cliente?

| Modelo | Ventaja | Riesgo |
|---|---|---|
| Una para todo | Simple | Un error o una filtración afecta a todos los clientes |
| **Una por cliente** (este repo) | Cada state tiene su dueño; daño acotado; auditoría por cliente | Más cuentas |
| Por cliente, separando plan y apply | Lo más profesional | Lo más trabajo |

Nombre: el **mismo prefijo** del cliente (`trendy-terraform`), así filtrar por `trendy-` muestra todo lo de Trendy. Un nombre de plataforma (`platform-terraform`) solo tiene sentido para la capa de bootstrap. Recuerda que en un proyecto compartido la separación es **parcial**: el aislamiento real es un proyecto por cliente.

### ¿dbt sirve para Spark o grandes volúmenes?

dbt no procesa datos: el motor sí. Con BigQuery (distribuido, procesa terabytes en segundos) casi nunca hace falta Spark para SQL. Spark (`dbt-databricks`, `dbt-spark`, o modelos Python en Dataproc con `dbt-bigquery`) conviene con datos en un lake, ML o transformaciones que no son SQL.

Con muchos datos, las técnicas clave son:

**Modelos incrementales** (lo más importante): procesar solo lo nuevo.

```sql
{{ config(
    materialized='incremental',
    incremental_strategy='insert_overwrite',
    partition_by={'field': 'report_date', 'data_type': 'date'},
    cluster_by=['campaign_id']
) }}

with bronze as (
    select * from {{ source('adverity', 'meta_ads_raw') }}
    {% if is_incremental() %}
    -- Solo los últimos 3 días: Meta corrige datos recientes con retraso
    where safe_cast(date as date) >= date_sub(current_date(), interval 3 day)
    {% endif %}
)
-- ... typed, deduped igual que hoy ...
```

La primera vez construye todo; luego solo reemplaza las particiones recientes. `dbt build --full-refresh` reprocesa todo. Otras estrategias: `merge` (upsert por llave) y `microbatch` (dbt ≥ 1.9).

**Particionado y clustering:** BigQuery cobra por bytes leídos; filtrar por partición lee solo esa parte.

**Materialización según el uso:** con mucho volumen silver pasa de `view` a `incremental`.

**No procesar todo en dev/CI:** filtrar por fecha cuando `target.name != 'prod'`, y *slim CI* (`dbt build --select state:modified+ --defer --state ./prod-artifacts`).

**Límites de costo:** `maximum_bytes_billed`.

| Volumen | Qué hacer |
|---|---|
| Miles a millones de filas | Lo que tiene este repo |
| Cientos de millones o más | Incrementales + particionado + clustering |
| Miles de modelos o CI lento | Slim CI |
| Datos en un lake, ML, no-SQL | Spark |

---

## Pendientes

Mejoras anotadas mientras construíamos, en el orden sugerido:

| # | Mejora | Por qué importa | Dificultad |
|---|---|---|---|
| 1 | Romper un test en un PR (país `VE` en el seed) | Ver al CI bloquear un cambio malo antes de producción | Baja |
| 2 | Condición de Workload Identity por `repository_id` | Evita que alguien que recree un repo con el mismo nombre entre a GCP | Baja |
| 3 | Limitar qué roles puede otorgar `trendy-terraform` (IAM Condition sobre `projectIamAdmin`) | Hoy podría darse Owner a sí misma | Media |
| 4 | Pipeline `terraform.yml`: plan en cada PR, apply al hacer merge | El flujo profesional: nadie aplica a mano | Media-alta |
| 5 | Silver incremental con particiones y clustering | Prepararlo para volúmenes reales | Media |
| 6 | Conectar una fuente real (`sources:`) en lugar del seed | Usarlo con datos de verdad | Media |

---

**Versiones con las que se construyó:** dbt-core 1.12.5 · dbt-bigquery 1.12.1 · dbt_utils 1.4.1 · uv 0.13.0 · Python 3.12 · Terraform 1.15 · proveedor google 7.x · octubre de 2026.
