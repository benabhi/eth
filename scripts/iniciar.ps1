# Arranque en un paso para Windows (lo llama iniciar.bat).
# 1) verifica Docker; 2) si falta .env, lo crea pidiendo los datos de tu app de EVE y
# genera ETH_VAULT_KEY; 3) levanta la app; 4) abre el navegador cuando responde.
# Mensajes sin acentos: Windows PowerShell 5.1 lee mal UTF-8 sin BOM.

$ErrorActionPreference = "Stop"
Set-Location (Split-Path -Parent $PSScriptRoot)

$compose = "docker-compose.release.yml"
$url = "http://localhost:4000"

function Pausa-Y-Sale($codigo) {
  Write-Host ""
  Read-Host "Presiona Enter para cerrar"
  exit $codigo
}

Write-Host "== EVE Trade Hunter ==" -ForegroundColor Cyan

# 1. Docker
docker info *> $null
if ($LASTEXITCODE -ne 0) {
  Write-Host "Docker no esta corriendo. Abri Docker Desktop, espera a que diga 'Running' y volve a ejecutar iniciar.bat." -ForegroundColor Yellow
  Pausa-Y-Sale 1
}

# 2. Configuracion (.env)
if (-not (Test-Path ".env")) {
  Write-Host ""
  Write-Host "Primera vez: hace falta tu aplicacion de EVE (ver README, paso 3)." -ForegroundColor Cyan
  Write-Host "Callback URL que tiene que tener: $url/auth/eve/callback"
  $clientId = Read-Host "Client ID"
  $secret = Read-Host "Secret Key"
  $contact = Read-Host "Tu email (EVE lo pide para poder contactarte)"

  if (-not $clientId -or -not $secret -or -not $contact) {
    Write-Host "Faltan datos: no se creo .env." -ForegroundColor Yellow
    Pausa-Y-Sale 1
  }

  $bytes = New-Object byte[] 32
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  $vaultKey = [Convert]::ToBase64String($bytes)

  $lines = Get-Content ".env.example" | ForEach-Object {
    switch -Regex ($_) {
      "^EVE_CLIENT_ID=" { "EVE_CLIENT_ID=$clientId"; break }
      "^EVE_CLIENT_SECRET=" { "EVE_CLIENT_SECRET=$secret"; break }
      "^ESI_CONTACT=" { "ESI_CONTACT=$contact"; break }
      "^ETH_VAULT_KEY=" { "ETH_VAULT_KEY=$vaultKey"; break }
      default { $_ }
    }
  }
  [System.IO.File]::WriteAllLines((Join-Path (Get-Location) ".env"), $lines, (New-Object System.Text.UTF8Encoding $false))

  Write-Host ""
  Write-Host "Se creo .env. GUARDA UNA COPIA de esta clave (cifra tus tokens de EVE):" -ForegroundColor Yellow
  Write-Host "ETH_VAULT_KEY=$vaultKey"
  Write-Host ""
}

# 3. Levantar
Write-Host "Levantando la app (la primera vez construye la imagen: unos minutos)..." -ForegroundColor Cyan
docker compose -f $compose up -d --build
if ($LASTEXITCODE -ne 0) {
  Write-Host "No se pudo levantar. Mira el error de arriba." -ForegroundColor Red
  Pausa-Y-Sale 1
}

# 4. Esperar y abrir el navegador
Write-Host "Esperando a que la app responda en $url ..."
for ($i = 0; $i -lt 120; $i++) {
  try {
    Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 3 | Out-Null
    Write-Host "Lista. Abriendo el navegador." -ForegroundColor Green
    Start-Process $url
    exit 0
  } catch {
    Start-Sleep -Seconds 5
  }
}

Write-Host "La app todavia no responde. Revisa: docker compose -f $compose logs -f app" -ForegroundColor Yellow
Pausa-Y-Sale 1
