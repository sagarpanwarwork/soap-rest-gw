$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$buildRoot = Join-Path $repoRoot 'build'
$packageRoot = Join-Path $buildRoot 'package'
$zipPath = Join-Path $buildRoot 'lambda_function.zip'

if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    throw 'Python is required. Install Python 3.13 and ensure python.exe is on PATH.'
}

if (Test-Path $packageRoot) { Remove-Item $packageRoot -Recurse -Force }
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null

python -m pip install --disable-pip-version-check --no-compile --target $packageRoot -r (Join-Path $repoRoot 'src/requirements.txt')
if ($LASTEXITCODE -ne 0) { throw 'pip install failed; Lambda package was not created.' }

Copy-Item (Join-Path $repoRoot 'src/lambda_function.py') $packageRoot
Compress-Archive -Path (Join-Path $packageRoot '*') -DestinationPath $zipPath -CompressionLevel Optimal

Write-Host "Lambda deployment package created: $zipPath" -ForegroundColor Green
Write-Host 'Verify that lambda_function.py, defusedxml/ and pystache/ are at the ZIP root.'
