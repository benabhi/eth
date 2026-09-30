#!/usr/bin/env bash
# Detiene EVE Trade Hunter (guarda el mercado en disco para el próximo arranque).
set -euo pipefail
cd "$(dirname "$0")"
docker compose -f docker-compose.release.yml stop
