$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Push-Location $root
try {
    if (-not (Test-Path '.venv\Scripts\python.exe')) {
        & python -m venv .venv
        if ($LASTEXITCODE -ne 0) { throw 'Python environment creation failed.' }
    }
    & .\.venv\Scripts\python.exe -m pip install -r backend\requirements-dev.txt
    if ($LASTEXITCODE -ne 0) { throw 'Python dependency installation failed.' }
    Push-Location frontend
    try {
        & npm.cmd ci
        if ($LASTEXITCODE -ne 0) { throw 'Frontend dependency installation failed.' }
    } finally { Pop-Location }
    & .\.venv\Scripts\python.exe scripts\configure.py
    if ($LASTEXITCODE -ne 0) { throw 'Configuration setup failed.' }
} finally { Pop-Location }
