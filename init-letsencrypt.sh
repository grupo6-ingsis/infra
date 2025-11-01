#!/bin/bash

# Script para inicializar Let's Encrypt
# Basado en: https://github.com/wmnnd/nginx-certbot

# Cargar variables del .env
set -a
source .env
set +a

# Verificar que las variables necesarias estén definidas
if [ -z "$NGINX_DOMAIN" ]; then
  echo "Error: NGINX_DOMAIN no está definido en .env"
  exit 1
fi

if [ -z "$LETSENCRYPT_EMAIL" ]; then
  echo "Error: LETSENCRYPT_EMAIL no está definido en .env"
  exit 1
fi

# Configuración desde variables de entorno
domains=($NGINX_DOMAIN)
email="$LETSENCRYPT_EMAIL"
staging=${LETSENCRYPT_STAGING:-0}  # Por defecto 0 (producción)

# Paths
data_path="./certbot"
rsa_key_size=4096

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

echo "### Iniciando configuración de Let's Encrypt..."
echo "### Dominio: ${domains[0]}"
echo "### Email: $email"
echo "### Modo: $([ $staging -eq 0 ] && echo 'Producción' || echo 'Staging/Testing')"
echo ""

# Verificar si ya existen certificados
if [ -d "$data_path/conf/live/${domains[0]}" ]; then
  read -p "Los certificados ya existen. ¿Deseas reemplazarlos? (y/N) " decision
  if [ "$decision" != "Y" ] && [ "$decision" != "y" ]; then
    exit
  fi
fi

# Crear directorios necesarios
if [ ! -e "$data_path/conf/options-ssl-nginx.conf" ] || [ ! -e "$data_path/conf/ssl-dhparams.pem" ]; then
  echo "### Descargando configuración SSL recomendada..."
  mkdir -p "$data_path/conf"
  curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf > "$data_path/conf/options-ssl-nginx.conf"
  curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot/certbot/ssl-dhparams.pem > "$data_path/conf/ssl-dhparams.pem"
  echo
fi

# Crear certificado dummy para iniciar nginx
echo "### Creando certificado dummy para ${domains[0]}..."
path="/etc/letsencrypt/live/${domains[0]}"
mkdir -p "$data_path/conf/live/${domains[0]}"
sudo docker compose run --rm --entrypoint "\
  openssl req -x509 -nodes -newkey rsa:$rsa_key_size -days 1\
    -keyout '$path/privkey.pem' \
    -out '$path/fullchain.pem' \
    -subj '/CN=localhost'" certbot
echo

# Iniciar nginx
echo "### Iniciando nginx..."
sudo docker compose up --force-recreate -d nginx
echo

# Eliminar certificado dummy
echo "### Eliminando certificado dummy para ${domains[0]}..."
sudo docker compose run --rm --entrypoint "\
  rm -Rf /etc/letsencrypt/live/${domains[0]} && \
  rm -Rf /etc/letsencrypt/archive/${domains[0]} && \
  rm -Rf /etc/letsencrypt/renewal/${domains[0]}.conf" certbot
echo

# Solicitar certificado real
echo "### Solicitando certificado de Let's Encrypt para ${domains[0]}..."

# Determinar si usar staging
if [ $staging != "0" ]; then staging_arg="--staging"; fi

# Construir argumentos de dominio
domain_args=""
for domain in "${domains[@]}"; do
  domain_args="$domain_args -d $domain"
done

# Solicitar certificado
sudo docker compose run --rm --entrypoint "\
  certbot certonly --webroot -w /var/www/certbot \
    $staging_arg \
    $domain_args \
    --email $email \
    --rsa-key-size $rsa_key_size \
    --agree-tos \
    --force-renewal" certbot
echo

# Recargar nginx
echo "### Recargando nginx..."
sudo docker compose exec nginx nginx -s reload

echo -e "${GREEN}### ¡Listo! Certificado SSL configurado correctamente.${NC}"
echo "### El certificado se renovará automáticamente cada 12 horas."