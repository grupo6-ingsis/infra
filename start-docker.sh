#!/bin/bash
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

# Levantar los contenedores
echo "Levantando Docker Compose..."
docker compose up -d

# Mostrar estado
docker compose ps
