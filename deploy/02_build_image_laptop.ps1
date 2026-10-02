<#
.SYNOPSIS
    Thin wrapper to build and push the EE Ops app image from a Windows laptop.

.DESCRIPTION
    Calls deploy/02_build_image_laptop.py, which handles PAT credentials
    (prompts on first use, caches for subsequent runs; reuses the other ED
    apps' saved PATs). No Docker, WSL or admin rights needed.

    Run from the repo root:
        powershell -ExecutionPolicy Bypass -File .\deploy\02_build_image_laptop.ps1

.PARAMETER ReuseLayer
    Re-push the existing .build/layer.tar without repacking (retry a failed push only).

.PARAMETER SkipPush
    Build the layer only (dry run).
#>
param(
    [switch]$ReuseLayer,
    [switch]$SkipPush
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "=== EE Ops App Deployment ===" -ForegroundColor Cyan
Write-Host ""

$buildArgs = @()
if ($ReuseLayer) { $buildArgs += "--reuse-layer"; Write-Host "  Mode: reuse existing layer" -ForegroundColor Gray }
if ($SkipPush)   { $buildArgs += "--skip-push";   Write-Host "  Push: SKIPPED (dry run)" -ForegroundColor Yellow }

# 'python' may open the Microsoft Store on CPUC laptops; prefer the 'py' launcher.
$pyExe = "py"
if (-not (Get-Command $pyExe -ErrorAction SilentlyContinue)) { $pyExe = "python" }
if (-not (Get-Command $pyExe -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: Neither 'py' nor 'python' found." -ForegroundColor Red
    exit 1
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
& $pyExe (Join-Path $scriptDir "02_build_image_laptop.py") @buildArgs
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "ERROR: Build failed (exit code $LASTEXITCODE)." -ForegroundColor Red
    Write-Host "  If 401: run  py deploy\02_build_image_laptop.py --clear-pat" -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "=== Image pushed ===" -ForegroundColor Green
if (-not $SkipPush) {
    Write-Host ""
    Write-Host "Next:" -ForegroundColor Cyan
    Write-Host "  Step 3: Run deploy/03_redeploy_sf.sql in Snowsight" -ForegroundColor White
    Write-Host "  Step 4: Run deploy/04_verify_sf.sql in Snowsight" -ForegroundColor White
    Write-Host "  (first deploy only: also run deploy/05_manage_access_sf.sql)" -ForegroundColor White
    Write-Host ""
}
