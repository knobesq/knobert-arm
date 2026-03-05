# Knobert WSL Arm — One command to join the octopus
#
# Usage:
#   $env:KNOBERT_KEY="your-arm-bridge-key"; irm https://raw.githubusercontent.com/knobesq/knobert-arm/main/wsl-arm.ps1 | iex
#
# Or save and run:
#   .\wsl-arm.ps1 -BridgeKey "your-key"
#
# What it does:
#   1. Removes existing "Knobert" WSL distro (if any)
#   2. Downloads Ubuntu 24.04 rootfs
#   3. Imports as WSL2 distro named "Knobert"
#   4. Creates a "knobert" user inside the distro
#   5. Runs the armstrap (which installs everything and starts the worker)

param(
    [string]$BridgeKey = $env:KNOBERT_KEY,
    [string]$InstallDir = "$env:USERPROFILE\WSL\Knobert",
    [string]$DistroName = "Knobert",
    [string]$RootfsUrl = "https://cdimages.ubuntu.com/ubuntu-wsl/noble/daily-live/current/noble-wsl-amd64.wsl"
)

if (-not $BridgeKey) {
    Write-Error "Set KNOBERT_KEY or pass -BridgeKey"
    exit 1
}

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Knobert WSL Arm Bootstrap" -ForegroundColor Cyan
Write-Host "  Distro:  $DistroName" -ForegroundColor Cyan
Write-Host "  Install: $InstallDir" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

# Step 1: Remove existing distro
$existing = wsl -l -q 2>$null | Where-Object { $_.Trim() -replace "`0","" -eq $DistroName }
if ($existing) {
    Write-Host "[1/5] Removing existing '$DistroName' distro..." -ForegroundColor Yellow
    wsl --unregister $DistroName
} else {
    Write-Host "[1/5] No existing '$DistroName' distro found" -ForegroundColor Green
}

# Step 2: Download Ubuntu rootfs
$rootfsPath = "$env:TEMP\noble-wsl-amd64.wsl"
if (-not (Test-Path $rootfsPath)) {
    Write-Host "[2/5] Downloading Ubuntu 24.04 rootfs (~374MB)..." -ForegroundColor Yellow
    Invoke-WebRequest -Uri $RootfsUrl -OutFile $rootfsPath -UseBasicParsing
    if (-not (Test-Path $rootfsPath)) {
        Write-Error "Download failed. Check your internet connection."
        exit 1
    }
} else {
    Write-Host "[2/5] Using cached rootfs at $rootfsPath" -ForegroundColor Green
    Write-Host "       (delete this file to force re-download)" -ForegroundColor DarkGray
}

# Step 3: Import as WSL2
Write-Host "[3/5] Importing as WSL2 distro '$DistroName'..." -ForegroundColor Yellow
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
wsl --import $DistroName $InstallDir $rootfsPath --version 2
if ($LASTEXITCODE -ne 0) {
    Write-Error "WSL import failed (exit code $LASTEXITCODE)"
    exit 1
}

# Step 4: Create knobert user and configure
Write-Host "[4/5] Setting up user and environment..." -ForegroundColor Yellow
wsl -d $DistroName -- bash -c @"
set -e
# Create knobert user if it doesn't exist
if ! id knobert &>/dev/null; then
    useradd -m -s /bin/bash -G sudo knobert
    echo 'knobert ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/knobert
fi
# Set default user for the distro
echo -e '[user]\ndefault=knobert' > /etc/wsl.conf
# Install basics
apt-get update -qq && apt-get install -y -qq curl git python3 python3-pip sudo >/dev/null 2>&1
"@

# Step 5: Run armstrap as knobert user
Write-Host "[5/5] Starting Knobert arm worker..." -ForegroundColor Green
Write-Host ""
wsl -d $DistroName -u knobert -- bash -c "export BRIDGE_KEY='$BridgeKey'; export MODE=bare; bash <(curl -fsSL https://raw.githubusercontent.com/knobesq/knobert-arm/main/armstrap.sh)"
