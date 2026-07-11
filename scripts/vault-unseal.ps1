param(
  [string]$KeysFile = (Join-Path $PSScriptRoot "vault\init\keys.txt"),
  [int]$UnsealThreshold = 3
)

$VaultContainer = "vault"
$VaultAddr = "http://localhost:8200"
$VaultApi = "http://localhost:8091"

function Get-SealStatus {
  try { return Invoke-RestMethod -Uri "$VaultApi/v1/sys/seal-status" } catch { return $null }
}

function Unseal-Shard {
  param([string]$Key)
  $plainKey = "$Key".Trim()
  $body = @{key=$plainKey} | ConvertTo-Json
  try { return Invoke-RestMethod -Uri "$VaultApi/v1/sys/unseal" -Method Put -Body $body -ContentType "application/json" } catch { return $null }
}

function Initialize-Vault {
  $body = @{secret_shares=5; secret_threshold=$UnsealThreshold} | ConvertTo-Json
  return Invoke-RestMethod -Uri "$VaultApi/v1/sys/init" -Method Put -Body $body -ContentType "application/json"
}

# ─── Check container ───────────────────────────────────────────────────────
$running = docker ps --filter "name=$VaultContainer" --format "{{.Names}}" 2>$null
if (-not $running) {
  Write-Host "Vault container '$VaultContainer' is not running. Start it first:" -ForegroundColor Red
  Write-Host "  docker compose -f compose/vault.yml up -d" -ForegroundColor Yellow
  exit 1
}

# ─── Check seal status ─────────────────────────────────────────────────────
$status = Get-SealStatus
if (-not $status) {
  Write-Host "Could not get Vault status. Is Vault running?" -ForegroundColor Red
  exit 1
}

if ($status.sealed -eq $false) {
  Write-Host "Vault is already unsealed." -ForegroundColor Green
  Write-Host "  Cluster: $($status.cluster_name)" -ForegroundColor Cyan
  Write-Host "  Version: $($status.version)" -ForegroundColor Cyan
  exit 0
}

Write-Host "Vault is sealed. Progress: $($status.progress)/$($status.t)" -ForegroundColor Yellow

# ─── Check keys file ───────────────────────────────────────────────────────
if (-not (Test-Path $KeysFile)) {
  Write-Host "No keys file found at: $KeysFile" -ForegroundColor Yellow
  Write-Host ""

  $choice = Read-Host "Initialize Vault for the first time? (y/N)"
  if ($choice -ne "y") { exit 0 }

  $init = Initialize-Vault
  if (-not $init -or -not $init.root_token) {
    Write-Host "Initialization failed." -ForegroundColor Red
    exit 1
  }

  $null = New-Item -ItemType Directory -Path (Split-Path $KeysFile -Parent) -Force
  @"
Vault initialized at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
──────────────────────────────────────────────────────────
Unseal Keys (save these securely — cannot be recovered):
$($init.unseal_keys_b64 -join "`n")
──────────────────────────────────────────────────────────
Root Token: $($init.root_token)
"@ | Out-File -FilePath $KeysFile -Encoding utf8

  Write-Host "Keys saved to: $KeysFile" -ForegroundColor Green
  $keys = $init.unseal_keys_b64
} else {
  $content = [System.IO.File]::ReadAllLines($KeysFile) | Where-Object { $_ -match '^[A-Za-z0-9+/=]+$' }
  if (-not $content -or $content.Count -eq 0) {
    Write-Host "No valid unseal keys found in: $KeysFile" -ForegroundColor Red
    Write-Host "Add one base64-encoded key per line." -ForegroundColor Yellow
    exit 1
  }
  $keys = $content | Select-Object -First $UnsealThreshold
}

# ─── Unseal via API ────────────────────────────────────────────────────────
foreach ($key in $keys) {
  $result = Unseal-Shard -Key $key
  if (-not $result) {
    Write-Host "  Unseal API call failed for a key." -ForegroundColor Red
    exit 1
  }
  if ($result.sealed -eq $false) {
    Write-Host "Vault successfully unsealed!" -ForegroundColor Green
    break
  }
  Write-Host "  Unseal progress: $($result.progress)/$($result.t)" -ForegroundColor Cyan
}

$final = Get-SealStatus
if ($final.sealed -eq $false) {
  Write-Host "Vault successfully unsealed!" -ForegroundColor Green
  Write-Host "  Cluster: $($final.cluster_name)" -ForegroundColor Cyan
  Write-Host "  Version: $($final.version)" -ForegroundColor Cyan
} else {
  $remaining = $final.t - $final.progress
  Write-Host "Still sealed - need $remaining more key(s)." -ForegroundColor Red
  exit 1
}
