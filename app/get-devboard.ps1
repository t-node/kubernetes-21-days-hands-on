# Fetch the DevBoard application source into app\devboard\ (PowerShell).
$ErrorActionPreference = "Stop"
$here = $PSScriptRoot
$repo = "https://github.com/t-node/devboard.git"
$dest = Join-Path $here "devboard"

if (Test-Path (Join-Path $dest ".git")) {
    Write-Host "==> updating existing checkout in app\devboard"
    git -C $dest pull --ff-only
} else {
    Write-Host "==> cloning $repo into app\devboard"
    git clone --depth 1 $repo $dest
}

Write-Host ""
Write-Host "Source ready. app\devboard\backend\main.go is the Go API."
