#!/bin/bash
set -euo pipefail

# Archivo: start-docker.sh (mejorado)

# Cargar .env
set -a
source .env
set +a

# Normalizar nombres de dominio/email (soporta variantes)
DOMAIN="${DOMAIN_NAME:-${NGINX_DOMAIN:-}}"
CERT_EMAIL="${CERTBOT_EMAIL:-${LETSENCRYPT_EMAIL:-}}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.dev.yml}"

: "${DOMAIN:?Error: DOMAIN or NGINX_DOMAIN not set in .env}"
: "${CERT_EMAIL:?Error: CERTBOT_EMAIL or LETSENCRYPT_EMAIL not set in .env}"

# Detect docker compose command
if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
elif docker-compose version >/dev/null 2>&1; then
  COMPOSE_CMD="docker-compose"
else
  echo "Error: neither 'docker compose' nor 'docker-compose' available"
  exit 1
fi

echo "========================================"
echo "Starting DEV deployment with HTTPS..."
echo " Domain: $DOMAIN"
echo " Email: $CERT_EMAIL"
echo " Compose file: $COMPOSE_FILE"
echo " Compose command: $COMPOSE_CMD"
echo "========================================"
echo

# Ensure networks (optional)
docker network inspect microservices-network >/dev/null 2>&1 || docker network create microservices-network
docker network inspect frontend-network >/dev/null 2>&1 || docker network create frontend-network

# GHCR login if creds present
if [ -n "${GHCR_PAT:-}" ] && [ -n "${GHCR_USER:-}" ]; then
  echo "$GHCR_PAT" | docker login ghcr.io -u "$GHCR_USER" --password-stdin
  if [ $? -ne 0 ]; then
    echo "Warning: Could not login to GHCR, continuing anyway"
  fi
else
  echo "GHCR credentials not provided, skipping GHCR login"
fi
echo

# Mapear variables de imagen a servicio y volúmenes nombrados
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

# Para cada imagen: comprobar id antes, hacer pull, comprobar id después
for envvar in "${!IMAGE_ENV_TO_SERVICE[@]}"; do
  image="${!envvar:-}"
  service="${IMAGE_ENV_TO_SERVICE[$envvar]}"
  if [ -z "$image" ]; then
    echo "Skipping $envvar: not set"
    continue
  fi

  echo "Checking image for service $service -> $image"

  pre_id=$(docker image inspect --format='{{.Id}}' "$image" 2>/dev/null || true)
  echo "  before id: ${pre_id:-<missing>}"

  if ! docker pull "$image"; then
    echo "  Warning: docker pull failed for $image, skipping comparison"
    continue
  fi

  post_id=$(docker image inspect --format='{{.Id}}' "$image" 2>/dev/null || true)
  echo "  after id: ${post_id:-<missing>}"

  if [ "$pre_id" != "$post_id" ]; then
    echo "  Image changed for $service"
    changed_services+=("$service")
  else
    echo "  No change for $service"
  fi
  echo
done

# Manejar certificados (comprobación básica en volumen nombrado si corresponde)
CERT_VOLUME="${CERT_VOLUME:-infrastructure_certbot-etc-dev}"
CERT_PATH="/etc/letsencrypt/live/$DOMAIN"
echo "Checking SSL certificates in volume $CERT_VOLUME..."
if docker run --rm -v "$CERT_VOLUME":/etc/letsencrypt alpine test -f "$CERT_PATH/fullchain.pem"; then
  CERT_EXPIRES=$(docker run --rm -v "$CERT_VOLUME":/etc/letsencrypt alpine sh -c "apk add --no-cache openssl >/dev/null 2>&1 && openssl x509 -noout -enddate -in $CERT_PATH/fullchain.pem | cut -d= -f2" || echo "Unknown")
  echo "  Certificates found, expires: $CERT_EXPIRES"
else
  echo "  No certificates found in volume $CERT_VOLUME (will continue)"
fi
echo

# Si hay servicios cambiados: stop + rm con volúmenes nombrados mapeados
if [ ${#changed_services[@]} -gt 0 ]; then
  echo "Services with changed images: ${changed_services[*]}"
  for svc in "${changed_services[@]}"; do
    vol="${SERVICE_TO_VOLUME[$svc]:-}"
    echo "Recreating service $svc"
    # Stop and remove container (and anonymous volumes). For named volumes, remove explicitly.
    $COMPOSE_CMD -f "$COMPOSE_FILE" stop "$svc" || true
    $COMPOSE_CMD -f "$COMPOSE_FILE" rm -s -f -v "$svc" || true

    if [ -n "$vol" ]; then
      if docker volume inspect "$vol" >/dev/null 2>&1; then
        echo "  Removing named volume $vol"
        docker volume rm "$vol" || true
      else
        echo "  Named volume $vol does not exist or already removed"
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
echo
echo "DEV DEPLOYMENT COMPLETED"
