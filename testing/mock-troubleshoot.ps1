# Mock troubleshoot stub for collect.ps1 logic tests.
# Accepts any arguments (they are ignored) and writes a minimal .tar.gz to the
# current directory with the cluster-resources/ and router-logs/ structure that
# the assertion step checks.
$ts = Get-Date -Format 'yyyy-MM-ddTHH-mm-ss'
$dir = "support-bundle-$ts"

New-Item -ItemType Directory -Force "$dir\cluster-resources" | Out-Null
New-Item -ItemType Directory -Force "$dir\router-logs" | Out-Null
'{"items":[{"metadata":{"name":"mock-node"}}]}' |
  Set-Content "$dir\cluster-resources\nodes.json" -Encoding utf8
'mock router log' |
  Set-Content "$dir\router-logs\router-0.txt" -Encoding utf8

tar -czf "$dir.tar.gz" $dir
if ($LASTEXITCODE -ne 0) {
    Write-Error "tar failed with exit code $LASTEXITCODE"
    exit $LASTEXITCODE
}

Remove-Item -Recurse -Force $dir
Write-Host "mock-troubleshoot: wrote $dir.tar.gz"
