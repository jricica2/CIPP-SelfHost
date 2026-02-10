<#
.SYNOPSIS
    Interactive setup script for CIPP Self-Hosted deployment.
.DESCRIPTION
    Guides you through configuring the .env file, building the frontend,
    and starting the Docker containers for a self-hosted CIPP instance.
.PARAMETER SamAppId
    The SAM Application (Client) ID. If not provided, prompted interactively.
.PARAMETER SamAppSecret
    The SAM Application Secret. If not provided, prompted interactively.
.PARAMETER SamTenantId
    The SAM Tenant ID. If not provided, prompted interactively.
.PARAMETER SamRefreshToken
    The SAM Refresh Token. If not provided, prompted interactively.
.PARAMETER PortalClientId
    The Portal Login App Client ID. If not provided, prompted interactively.
.PARAMETER PortalClientSecret
    The Portal Login App Secret. If not provided, prompted interactively.
.PARAMETER PortalTenantId
    The Portal Tenant ID. If not provided, prompted interactively.
.PARAMETER Hostname
    The hostname or IP for CIPP access. If not provided, prompted interactively.
.PARAMETER AdminUpn
    The initial admin user's email/UPN. If not provided, prompted interactively.
.PARAMETER SkipBuild
    Skip the frontend build step (if already built).
.PARAMETER StartContainers
    Automatically start Docker containers after setup.
.EXAMPLE
    .\setup.ps1
    # Runs interactively, prompting for all values
.EXAMPLE
    .\setup.ps1 -Hostname "cipp.local" -AdminUpn "admin@contoso.com" -StartContainers
    # Partially parameterized, prompts for remaining values
#>
[CmdletBinding()]
param(
    [string]$SamAppId,
    [string]$SamAppSecret,
    [string]$SamTenantId,
    [string]$SamRefreshToken,
    [string]$PortalClientId,
    [string]$PortalClientSecret,
    [string]$PortalTenantId,
    [string]$Hostname,
    [string]$AdminUpn,
    [switch]$SkipBuild,
    [switch]$StartContainers
)

$ErrorActionPreference = 'Stop'
$ScriptDir = $PSScriptRoot

function Read-PromptValue {
    param(
        [string]$Prompt,
        [string]$Default,
        [switch]$Required,
        [switch]$IsSecret
    )
    $displayPrompt = $Prompt
    if ($Default) { $displayPrompt += " [$Default]" }
    $displayPrompt += ": "

    if ($IsSecret) {
        $secure = Read-Host -Prompt $displayPrompt -AsSecureString
        $value = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        )
    } else {
        $value = Read-Host -Prompt $displayPrompt
    }

    if ([string]::IsNullOrWhiteSpace($value)) { $value = $Default }

    if ($Required -and [string]::IsNullOrWhiteSpace($value)) {
        Write-Host "ERROR: This value is required." -ForegroundColor Red
        return Read-PromptValue -Prompt $Prompt -Default $Default -Required:$Required -IsSecret:$IsSecret
    }
    return $value
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  CIPP Self-Hosted Setup" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
Write-Host "[1/6] Checking prerequisites..." -ForegroundColor Yellow

# Check Docker
try {
    $null = docker --version 2>&1
    Write-Host "  OK - Docker found" -ForegroundColor Green
} catch {
    Write-Host "  ERROR - Docker is not installed or not in PATH" -ForegroundColor Red
    Write-Host "  Install Docker Desktop from https://docker.com" -ForegroundColor Red
    exit 1
}

# Check Node.js
try {
    $null = node --version 2>&1
    Write-Host "  OK - Node.js found" -ForegroundColor Green
} catch {
    Write-Host "  ERROR - Node.js is not installed or not in PATH" -ForegroundColor Red
    Write-Host "  Install Node.js 22 LTS from https://nodejs.org" -ForegroundColor Red
    exit 1
}

# Check CIPP repo
$CippFrontendDir = Join-Path $ScriptDir '..' 'CIPP'
if (Test-Path (Join-Path $CippFrontendDir 'package.json')) {
    Write-Host "  OK - CIPP frontend repo found" -ForegroundColor Green
} else {
    Write-Host "  ERROR - CIPP frontend repo not found at: $CippFrontendDir" -ForegroundColor Red
    Write-Host "  Clone your CIPP fork as a sibling directory to CIPP-SelfHost" -ForegroundColor Red
    exit 1
}

# Check CIPP-API repo
$CippApiDir = Join-Path $ScriptDir '..' 'CIPP-API'
if (Test-Path (Join-Path $CippApiDir 'Dockerfile')) {
    Write-Host "  OK - CIPP-API repo found" -ForegroundColor Green
} else {
    Write-Host "  ERROR - CIPP-API repo not found at: $CippApiDir" -ForegroundColor Red
    Write-Host "  Clone your CIPP-API fork as a sibling directory to CIPP-SelfHost" -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# Collect configuration
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "[2/6] SAM Application Credentials" -ForegroundColor Yellow
Write-Host "  These come from your CIPP SAM app registration." -ForegroundColor Gray
Write-Host "  (The app that accesses Microsoft Graph on your tenant)" -ForegroundColor Gray
Write-Host ""

if (-not $SamAppId) { $SamAppId = Read-PromptValue -Prompt "SAM Application (Client) ID" -Required }
if (-not $SamAppSecret) { $SamAppSecret = Read-PromptValue -Prompt "SAM Application Secret" -Required -IsSecret }
if (-not $SamTenantId) { $SamTenantId = Read-PromptValue -Prompt "SAM Tenant ID" -Required }
if (-not $SamRefreshToken) { $SamRefreshToken = Read-PromptValue -Prompt "SAM Refresh Token" -Required -IsSecret }

Write-Host ""
Write-Host "[3/6] Portal Login App Registration" -ForegroundColor Yellow
Write-Host "  Create a NEW app registration in Entra ID for portal login." -ForegroundColor Gray
Write-Host "  Type: Web, Single tenant" -ForegroundColor Gray
Write-Host "  Permissions: openid, profile, email (delegated)" -ForegroundColor Gray
Write-Host ""

if (-not $PortalTenantId) { $PortalTenantId = Read-PromptValue -Prompt "Portal Tenant ID" -Default $SamTenantId -Required }
if (-not $PortalClientId) { $PortalClientId = Read-PromptValue -Prompt "Portal App Client ID" -Required }
if (-not $PortalClientSecret) { $PortalClientSecret = Read-PromptValue -Prompt "Portal App Client Secret" -Required -IsSecret }

Write-Host ""
Write-Host "[4/6] General Configuration" -ForegroundColor Yellow
Write-Host ""

if (-not $Hostname) { $Hostname = Read-PromptValue -Prompt "Hostname or IP to access CIPP (e.g., cipp.local, 192.168.1.100)" -Default "localhost" -Required }
if (-not $AdminUpn) { $AdminUpn = Read-PromptValue -Prompt "Initial admin email/UPN (e.g., admin@contoso.com)" -Required }

# Generate session secret
$SessionSecret = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 32 | ForEach-Object { [char]$_ })

# Remind about redirect URI
Write-Host ""
Write-Host "  IMPORTANT: Ensure your Portal app registration has this redirect URI:" -ForegroundColor Yellow
Write-Host "  https://$Hostname/auth/callback" -ForegroundColor White
Write-Host ""

# ---------------------------------------------------------------------------
# Write .env file
# ---------------------------------------------------------------------------
Write-Host "[5/6] Writing .env file..." -ForegroundColor Yellow

$envContent = @"
# CIPP Self-Host Configuration
# Generated by setup.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

# SAM Credentials
SAM_APPLICATION_ID=$SamAppId
SAM_APPLICATION_SECRET=$SamAppSecret
SAM_TENANT_ID=$SamTenantId
SAM_REFRESH_TOKEN=$SamRefreshToken

# Portal Login App
PORTAL_TENANT_ID=$PortalTenantId
PORTAL_CLIENT_ID=$PortalClientId
PORTAL_CLIENT_SECRET=$PortalClientSecret

# General Config
CIPP_HOSTNAME=$Hostname
SESSION_SECRET=$SessionSecret
DEFAULT_ADMIN_UPN=$AdminUpn
"@

$envPath = Join-Path $ScriptDir '.env'
$envContent | Out-File -FilePath $envPath -Encoding utf8 -Force
Write-Host "  OK - .env written to $envPath" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Build frontend
# ---------------------------------------------------------------------------
if (-not $SkipBuild) {
    Write-Host ""
    Write-Host "[6/6] Building CIPP frontend..." -ForegroundColor Yellow
    Write-Host "  This may take a few minutes on first run." -ForegroundColor Gray

    Push-Location $CippFrontendDir
    try {
        Write-Host "  Installing dependencies..." -ForegroundColor Gray
        npm install 2>&1 | Out-Null
        Write-Host "  Running build..." -ForegroundColor Gray
        npx next build 2>&1 | Out-Null
        Write-Host "  OK - Frontend built to $CippFrontendDir\out" -ForegroundColor Green
    } catch {
        Write-Host "  ERROR - Frontend build failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  You can retry manually: cd $CippFrontendDir && npm install && npx next build" -ForegroundColor Red
    } finally {
        Pop-Location
    }
} else {
    Write-Host ""
    Write-Host "[6/6] Skipping frontend build (-SkipBuild)" -ForegroundColor Yellow
    if (-not (Test-Path (Join-Path $CippFrontendDir 'out' 'index.html'))) {
        Write-Host "  WARNING: Frontend output not found at $CippFrontendDir\out" -ForegroundColor Red
        Write-Host "  Run: cd $CippFrontendDir && npm install && npx next build" -ForegroundColor Red
    }
}

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Setup Complete" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "To start CIPP:" -ForegroundColor Cyan
Write-Host "  cd $ScriptDir" -ForegroundColor White
Write-Host "  docker-compose up -d" -ForegroundColor White
Write-Host ""
Write-Host "Then open: https://$Hostname" -ForegroundColor Cyan
Write-Host ""
Write-Host "To view logs:" -ForegroundColor Gray
Write-Host "  docker-compose logs -f" -ForegroundColor White
Write-Host ""
Write-Host "To stop:" -ForegroundColor Gray
Write-Host "  docker-compose down" -ForegroundColor White
Write-Host ""

if ($StartContainers) {
    Write-Host "Starting containers..." -ForegroundColor Yellow
    Push-Location $ScriptDir
    docker-compose up -d
    Pop-Location
    Write-Host ""
    Write-Host "Containers starting. Wait ~60 seconds for initial setup." -ForegroundColor Yellow
    Write-Host "Then open: https://$Hostname" -ForegroundColor Cyan
}
