# -----------------------------
# Script para levantar Docker Compose con login automático a GHCR
# -----------------------------
# Cargar variables del .env
set -a           # exporta todas las variables automáticamente
source .env
set +a
# Variables de entorno (setearlas antes de ejecutar el script o exportarlas en .bashrc/.zshrc)
GHCR_USER="${GHCR_USER}"
GHCR_PAT="${GHCR_PAT}"

# Login automático en GHCR
echo "Haciendo login en GHCR..."
echo "$GHCR_PAT" | docker login ghcr.io -u "$GHCR_USER" --password-stdin
if [ $? -ne 0 ]; then
  echo "Error: no se pudo loguear en GHCR"
  exit 1
fi

# Generar nginx.conf desde template
echo "Generando nginx.conf desde template..."
envsubst '${NGINX_SERVER_NAME} ${NGINX_DOMAIN}' < nginx.conf.template > nginx.conf


sudo docker compose down

# Pull images with specific tags from .env
sudo docker pull "$SNIPPET_SERVICE_IMAGE"
sudo docker pull "$SNIPPET_ENGINE_IMAGE"
sudo docker pull "$AUTH_SERVICE_IMAGE"
sudo docker pull ghcr.io/austral-ingsis/snippet-asset-service:main.14
sudo docker pull mcr.microsoft.com/azure-storage/azurite


# Levantar los contenedores
echo "Levantando Docker Compose..."
sudo docker compose up --build -d

# Mostrar estado
sudo docker compose ps