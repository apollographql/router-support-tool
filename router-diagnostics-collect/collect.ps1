# Collects a router-diagnostics support bundle for mode: local. Caches a pinned
# support-bundle binary locally, then runs support-bundle against the cluster's
# discoverable specs.
#
# Usage: collect.ps1 -Namespace <namespace>
[CmdletBinding()]
param(
    [Parameter(Mandatory, HelpMessage = 'Kubernetes namespace where router-diagnostics is installed')]
    [string]$Namespace
)

$ErrorActionPreference = 'Stop'

# renovate: datasource=github-releases depName=replicatedhq/troubleshoot
$SupportBundleVersion = "0.134.1"

# Fail early if a required tool is missing
$Missing = @()
if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    $Missing += 'kubectl'
}
if ($Missing.Count -gt 0) {
    Write-Error "error: missing required tool(s): $($Missing -join ' ') - install them and re-run"
    exit 1
}

# --- Ensure the pinned support-bundle binary is cached locally. Named with its version
# so a Renovate bump downloads a fresh binary rather than silently reusing a stale one. ---
$CacheDir = if ($env:ROUTER_DIAGNOSTICS_CACHE_DIR) { $env:ROUTER_DIAGNOSTICS_CACHE_DIR } else { Join-Path $env:USERPROFILE '.router-diagnostics' }
$Bin = Join-Path $CacheDir "bin\support-bundle-v${SupportBundleVersion}.exe"

if (-not (Test-Path $Bin)) {
    $Asset = "support-bundle_windows_amd64.zip"
    $Url = "https://github.com/replicatedhq/troubleshoot/releases/download/v${SupportBundleVersion}/${Asset}"

    $null = New-Item -ItemType Directory -Force -Path (Join-Path $CacheDir 'bin')

    $TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
    $null = New-Item -ItemType Directory -Force -Path $TmpDir
    $TmpZip = Join-Path $TmpDir "${Asset}"
    $TmpBin = Join-Path $TmpDir 'support-bundle.exe'

    try {
        Invoke-WebRequest -Uri $Url -OutFile $TmpZip -UseBasicParsing
        Expand-Archive -Path $TmpZip -DestinationPath $TmpDir
        Move-Item -Path $TmpBin -Destination $Bin
        Write-Host "router-diagnostics: cached support-bundle v${SupportBundleVersion}" -ForegroundColor Cyan
    } finally {
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $TmpDir
    }
}

& $Bin --load-cluster-specs --namespace $Namespace --auto-update=false --interactive=false
exit $LASTEXITCODE
