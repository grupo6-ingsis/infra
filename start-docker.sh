#!/bin/bash
# -----------------------------
# Script de Deploy con recreación selectiva
# -----------------------------

set -e   # Si cualquier comando falla, el script se corta automáticamente

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

  # ============================================================
  #   OBTENER DIGEST REMOTO DESPUÉS DEL PULL
  #   docker pull siempre devuelve una línea "Digest: sha256:xxxx"
  # ============================================================
  REMOTE_DIGEST=$(sudo docker pull "$IMAGE" | grep Digest | awk '{print $2}')

  # ============================================================
  #   OBTENER DIGEST LOCAL (FORMA FIABLE)
  #   'docker images --digests' siempre muestra los digests,
  #   incluso cuando 'docker inspect' NO los devuelve.
  # ============================================================
  LOCAL_DIGEST=$(sudo docker images --digests "$IMAGE" | awk 'NR==2 {print $3}')

  echo "Digest remoto: $REMOTE_DIGEST"
  echo "Digest local : $LOCAL_DIGEST"
  echo ""

  # -----------------------------
  # Comparación real del digest
  # -----------------------------
  if [ -z "$LOCAL_DIGEST" ]; then
    echo "No existe digest local → Instalación inicial"
    CHANGED=1
  elif [ "$LOCAL_DIGEST" != "$REMOTE_DIGEST" ]; then
    echo "La imagen CAMBIÓ → Recreando $SERVICE_NAME"
    CHANGED=1
  else
    echo "La imagen NO cambió → Nada que hacer"
    CHANGED=0
  fi

  # -----------------------------
  # Si cambió: recrear servicio + borrar volúmenes del servicio
  # -----------------------------
  if [ $CHANGED -eq 1 ]; then
    echo "→ Borrando contenedores y volúmenes de $SERVICE_NAME"
    sudo docker compose rm -sfv $SERVICE_NAME $EXTRA_SERVICES

    echo "→ Levantando nuevamente $SERVICE_NAME"
    sudo docker compose up -d $EXTRA_SERVICES $SERVICE_NAME

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
sudo docker compose ps
echo "-----------------------------------------------"
echo "Deploy completo!"
