#!/bin/bash
# -----------------------------
# Script de Deploy con recreación selectiva
# -----------------------------

set -e

# Cargar variables del .env
set -a
source .env
set +a

GHCR_USER="${GHCR_USER}"
GHCR_PAT="${GHCR_PAT}"

# -----------------------------
# Login GHCR
# -----------------------------
echo "Haciendo login en GHCR..."
echo "$GHCR_PAT" | docker login ghcr.io -u "$GHCR_USER" --password-stdin
echo "OK!"

# -----------------------------
# Función: recrear servicio solo si cambió la imagen
# -----------------------------
recreate_if_changed() {
  SERVICE_NAME="$1"
  IMAGE="$2"
  EXTRA_SERVICES="$3"

  echo "-----------------------------------------------"
  echo "Chequeando imagen para: $SERVICE_NAME"
  echo "Imagen: $IMAGE"
  echo "-----------------------------------------------"

  # Obtener digest remoto
  REMOTE_DIGEST=$(docker pull "$IMAGE" | grep Digest | awk '{print $2}')

  # Obtener digest local
  LOCAL_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "$IMAGE" 2>/dev/null | cut -d'@' -f2)

  # Comparación
  if [ -z "$LOCAL_DIGEST" ]; then
    echo "No se encontró digest local → Instalación inicial"
    CHANGED=1
  elif [ "$LOCAL_DIGEST" != "$REMOTE_DIGEST" ]; then
    echo "La imagen cambió → RECREANDO $SERVICE_NAME"
    CHANGED=1
  else
    echo "La imagen NO cambió → NADA QUE HACER"
    CHANGED=0
  fi

  if [ $CHANGED -eq 1 ]; then
    echo "→ Borrando contenedores y volúmenes solo de $SERVICE_NAME"
    docker compose rm -sfv $SERVICE_NAME $EXTRA_SERVICES

    echo "→ Levantando nuevamente $SERVICE_NAME"
    docker compose up -d $EXTRA_SERVICES $SERVICE_NAME

    echo "✔ $SERVICE_NAME actualizado!"
    echo ""
  fi
}

# -----------------------------
# Ejecutar para cada servicio
# -----------------------------

# SNIPPET SERVICE
recreate_if_changed "snippet-service" "$SNIPPET_SERVICE_IMAGE" "snippet-service-db"

# SNIPPET ENGINE
recreate_if_changed "snippet-engine" "$SNIPPET_ENGINE_IMAGE" "snippet-engine-db"

# AUTHORIZATION
recreate_if_changed "authorization" "$AUTH_SERVICE_IMAGE" "authorization-db"

# FRONTEND
recreate_if_changed "frontend" "$FRONTEND_IMAGE"

echo ""
echo "-----------------------------------------------"
echo "Estado final de los contenedores:"
docker compose ps
echo "-----------------------------------------------"
echo "Deploy completo!"
