#!/usr/bin/env bash
# Arranque en un paso para macOS y Linux: verifica Docker, crea .env la primera vez
# (pide los datos de tu app de EVE y genera ETH_VAULT_KEY), levanta la app y abre el
# navegador cuando responde.
set -euo pipefail
cd "$(dirname "$0")"

COMPOSE=docker-compose.release.yml
URL=http://localhost:4000

echo "== EVE Trade Hunter =="

if ! docker info >/dev/null 2>&1; then
  echo "Docker no está corriendo. Abrí Docker y volvé a ejecutar ./iniciar.sh."
  exit 1
fi

if [ ! -f .env ]; then
  echo
  echo "Primera vez: hace falta tu aplicación de EVE (ver README, paso 3)."
  echo "Callback URL que tiene que tener: $URL/auth/eve/callback"
  read -rp "Client ID: " client_id
  read -rp "Secret Key: " secret
  read -rp "Tu email (EVE lo pide para poder contactarte): " contact

  if [ -z "$client_id" ] || [ -z "$secret" ] || [ -z "$contact" ]; then
    echo "Faltan datos: no se creó .env."
    exit 1
  fi

  vault_key=$(head -c 32 /dev/urandom | base64)

  sed -e "s|^EVE_CLIENT_ID=.*|EVE_CLIENT_ID=$client_id|" \
      -e "s|^EVE_CLIENT_SECRET=.*|EVE_CLIENT_SECRET=$secret|" \
      -e "s|^ESI_CONTACT=.*|ESI_CONTACT=$contact|" \
      -e "s|^ETH_VAULT_KEY=.*|ETH_VAULT_KEY=$vault_key|" \
      .env.example > .env

  echo
  echo "Se creó .env. GUARDÁ UNA COPIA de esta clave (cifra tus tokens de EVE):"
  echo "ETH_VAULT_KEY=$vault_key"
  echo
fi

echo "Levantando la app (la primera vez construye la imagen: unos minutos)..."
docker compose -f "$COMPOSE" up -d --build

echo "Esperando a que la app responda en $URL ..."
for _ in $(seq 1 120); do
  if curl -s -o /dev/null "$URL"; then
    echo "Lista: $URL"
    if command -v open >/dev/null; then open "$URL"; elif command -v xdg-open >/dev/null; then xdg-open "$URL" >/dev/null 2>&1 || true; fi
    exit 0
  fi
  sleep 5
done

echo "La app todavía no responde. Revisá: docker compose -f $COMPOSE logs -f app"
exit 1
