@echo off
rem Doble clic: detiene EVE Trade Hunter (guarda el mercado en disco para el proximo arranque).
cd /d "%~dp0"
docker compose -f docker-compose.release.yml stop
pause
