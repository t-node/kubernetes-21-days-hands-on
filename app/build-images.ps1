# Build the DevBoard images and load them into the kind cluster (PowerShell).
#
#   .\build-images.ps1                  # :1.0 into kind cluster "devops"
#   .\build-images.ps1 -Version 2.0     # :2.0
param(
    [string]$Version = "1.0",
    [string]$Cluster = "devops"
)
$ErrorActionPreference = "Stop"
$here = $PSScriptRoot
$src  = Join-Path $here "devboard"

if (-not (Test-Path $src)) {
    Write-Host "==> app source missing; fetching it"
    & (Join-Path $here "get-devboard.ps1")
}

Write-Host "==> building devboard-backend:$Version  (Go + Gin)"
docker build --build-arg "APP_VERSION=$Version" `
  -f (Join-Path $here "dockerfiles\backend.Dockerfile") `
  -t "devboard-backend:$Version" (Join-Path $src "backend")

Write-Host "==> building devboard-frontend:$Version  (React + Vite)"
docker build `
  -f (Join-Path $here "dockerfiles\frontend.Dockerfile") `
  -t "devboard-frontend:$Version" (Join-Path $src "frontend")

Write-Host "==> loading images into kind cluster '$Cluster'"
kind load docker-image "devboard-backend:$Version"  --name $Cluster
kind load docker-image "devboard-frontend:$Version" --name $Cluster

Write-Host ""
Write-Host "Done. Remember:"
Write-Host "  1. set imagePullPolicy: IfNotPresent in every Deployment"
Write-Host "  2. the backend Service MUST be named 'backend' on port 8080"
Write-Host "     (the frontend image proxies /api -> http://backend:8080)"
