#!/bin/bash
set -euo pipefail

# Cargar .env
set -a
source .env
set +a

DOMAIN="${NGINX_DOMAIN:-${DOMAIN_NAME:-}}"
CERT_EMAIL="${LETSENCRYPT_EMAIL:-${CERTBOT_EMAIL:-}}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"

# No abortar si falta email: solo warn
if [ -z "$DOMAIN" ]; then
  echo "Error: `NGINX_DOMAIN` o `DOMAIN_NAME` no está definido en .env"
  exit 1
fi
if [ -z "$CERT_EMAIL" ]; then
  echo "Warning: no se encontró `LETSENCRYPT_EMAIL` ni `CERTBOT_EMAIL` en .env — se continuará sin comprobación de correo para certbot"
fi

# Detectar comando docker compose (con sudo)
if sudo docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD="sudo docker compose"
elif sudo docker-compose version >/dev/null 2>&1; then
  COMPOSE_CMD="sudo docker-compose"
else
  echo "Error: neither 'sudo docker compose' nor 'sudo docker-compose' available"
  exit 1
fi

echo "========================================"
echo "Starting DEV deployment with HTTPS..."
echo " Domain: $DOMAIN"
echo " Email: ${CERT_EMAIL:-\<none\>}"
echo " Compose file: $COMPOSE_FILE"
echo " Compose command: $COMPOSE_CMD"
echo "========================================"
echo

# Asegurar la red del compose
sudo docker network inspect group6-gudelker-network >/dev/null 2>&1 || sudo docker network create group6-gudelker-network

# Login GHCR si hay creds
if [ -n "${GHCR_PAT:-}" ] && [ -n "${GHCR_USER:-}" ]; then
  echo "Logging in to GHCR..."
  echo "$GHCR_PAT" | sudo docker login ghcr.io -u "$GHCR_USER" --password-stdin || echo "Warning: GHCR login failed, continúo"
else
  echo "GHCR credentials not provided, skipping GHCR login"
fi
echo

# Mapear imágenes a servicios y volúmenes (ajustar si tu compose cambia nombres)
declare -A IMAGE_ENV_TO_SERVICE=(
  ["SNIPPET_SERVICE_IMAGE"]="snippet-service"
  ["SNIPPET_ENGINE_IMAGE"]="snippet-engine"
  ["AUTH_SERVICE_IMAGE"]="authorization"
  ["FRONTEND_IMAGE"]="frontend"
)
declare -A SERVICE_TO_VOLUME=(
  ["snippet-engine"]="snippet_engine_data"
  ["snippet-service"]="snippet_service_data"
  ["authorization"]="authorization_data"
  ["frontend"]="frontend-dist"
)

changed_services=()

for envvar in "${!IMAGE_ENV_TO_SERVICE[@]}"; do
  image="${!envvar:-}"
  service="${IMAGE_ENV_TO_SERVICE[$envvar]}"
  if [ -z "$image" ]; then
    echo "Skipping $envvar: not set"
    continue
  fi

  echo "Checking image for $service -> $image"
  pre_id=$(sudo docker image inspect --format='{{.Id}}' "$image" 2>/dev/null || true)
  echo "  before id: ${pre_id:-<missing>}"

  if sudo docker pull "$image"; then
    post_id=$(sudo docker image inspect --format='{{.Id}}' "$image" 2>/dev/null || true)
    echo "  after id: ${post_id:-<missing>}"
    if [ "$pre_id" != "$post_id" ]; then
      echo "  Image changed for $service"
      changed_services+=("$service")
    else
      echo "  No change for $service"
    fi
  else
    echo "  Warning: docker pull failed for $image, skipping comparison"
  fi
  echo
done

# Pull de imágenes extra usadas en compose
sudo docker pull ghcr.io/austral-ingsis/snippet-asset-service:main.14 2>/dev/null || true
sudo docker pull mcr.microsoft.com/azure-storage/azurite 2>/dev/null || true

# Comprobación de certificados local (si usás `./certbot/conf`)
CERT_LOCAL_PATH="./certbot/conf/live/$DOMAIN"
if [ -n "$CERT_EMAIL" ] && [ -f "$CERT_LOCAL_PATH/fullchain.pem" ]; then
  echo "Certificates found at $CERT_LOCAL_PATH"
elif [ -z "$CERT_EMAIL" ]; then
  echo "Skipping certificate email checks (no LETSENCRYPT_EMAIL/CERTBOT_EMAIL)"
else
  echo "No certificates found at $CERT_LOCAL_PATH"
fi
echo

# Recreate services with changed images, eliminando volúmenes nombrados correspondientes
if [ ${#changed_services[@]} -gt 0 ]; then
  echo "Services with changed images: ${changed_services[*]}"
  for svc in "${changed_services[@]}"; do
    vol="${SERVICE_TO_VOLUME[$svc]:-}"
    echo "Recreating $svc"
    $COMPOSE_CMD -f "$COMPOSE_FILE" stop "$svc" || true
    $COMPOSE_CMD -f "$COMPOSE_FILE" rm -s -f -v "$svc" || true
    if [ -n "$vol" ]; then
      if sudo docker volume inspect "$vol" >/dev/null 2>&1; then
        echo "  Removing named volume $vol"
        sudo docker volume rm "$vol" || true
      else
        echo "  Named volume $vol does not exist"
      fi
    fi
  done
else
  echo "No services changed, no volumes removed."
fi
echo

# Levantar todos los servicios
echo "Starting all DEV services..."
$COMPOSE_CMD -f "$COMPOSE_FILE" up -d --remove-orphans
echo

echo "Waiting for services to be ready..."
sleep 10

echo "Service status:"
$COMPOSE_CMD -f "$COMPOSE_FILE" ps
