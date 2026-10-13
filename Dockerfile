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