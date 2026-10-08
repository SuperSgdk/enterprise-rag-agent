param([switch]$NoBrowser, [switch]$AllowUnconfigured)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$python = Join-Path $root '.venv\Scripts\python.exe'
$backend = Join-Path $root 'backend'
$front = Join-Path $root 'frontend'
$runtime = Join-Path $root 'runtime'
New-Item -ItemType Directory -Force $runtime | Out-Null
$env:PYTHONUTF8 = '1'
Remove-Item Env:RAG_ENV_FILE -ErrorAction SilentlyContinue
& $python -c "from dotenv import dotenv_values; import sys; sys.exit(0 if dotenv_values(sys.argv[1]).get('DASHSCOPE_API_KEY','').strip() else 1)" "$backend\.env"
if ($LASTEXITCODE -ne 0 -and -not $AllowUnconfigured) {
    throw 'Fill DASHSCOPE_API_KEY in backend/.env first.'
}
$docker = (Get-Command docker -ErrorAction Stop).Source
function Test-DockerReady {
    try { & $docker info *> $null; return ($LASTEXITCODE -eq 0) } catch { return $false }
}
if (-not (Test-DockerReady)) {
    Start-Process (Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe') -WindowStyle Hidden
    $ready = $false
    for ($i=0; $i -lt 90; $i++) {
        Start-Sleep 2
        if (Test-DockerReady) { $ready=$true; break }
    }
    if (-not $ready) { throw 'Docker startup timed out.' }
}
& $docker compose --env-file "$root\deploy\.env" -f "$root\deploy\compose.yml" up -d --wait --wait-timeout 180
if ($LASTEXITCODE -ne 0) { throw 'Project project databases are not ready.' }
if (Test-Path "$runtime\processes.json") {
    $existing = Get-Content -LiteralPath "$runtime\processes.json" -Raw | ConvertFrom-Json
    foreach ($record in $existing) {
        $managedProcess = Get-Process -Id $record.pid -ErrorAction SilentlyContinue
        if (-not $managedProcess -or $managedProcess.StartTime.ToUniversalTime() -ne ([datetime]$record.started).ToUniversalTime()) {
            throw 'Managed process changed or exited. Stop the project before restarting.'
        }
        $port = if ($record.kind -eq 'api') { 8000 } else { 5173 }
        $listener = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
        if (-not $listener -or $listener.OwningProcess -notcontains $record.pid) {
            throw 'Managed port ownership changed. Stop the project before restarting.'
        }
    }
    $health = Invoke-RestMethod http://127.0.0.1:8000/health -TimeoutSec 5
    if (-not $health.ok) { throw 'Project project is running but its dependencies are unhealthy.' }
    Write-Output 'Project project already running: http://127.0.0.1:5173'
    if (-not $NoBrowser) { Start-Process 'http://127.0.0.1:5173' }
    return
}
foreach ($port in @(8000,5173)) {
    if (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue) {
        throw "Port $port is in use by another application."
    }
}
$node = (Get-Command node -ErrorAction Stop).Source
$api = Start-Process $python -ArgumentList @('-m','uvicorn','app.main:app','--host','127.0.0.1','--port','8000') -WorkingDirectory $backend -WindowStyle Hidden -PassThru -RedirectStandardOutput "$runtime\api.out.log" -RedirectStandardError "$runtime\api.err.log"
# Record the owned process immediately, including failed startup, for recovery.
$records = @(@{pid=$api.Id; started=$api.StartTime.ToUniversalTime().ToString('o'); kind='api'})
ConvertTo-Json -InputObject @($records) | Set-Content "$runtime\processes.json"
$ready = $false
for ($i=0; $i -lt 60; $i++) {
    Start-Sleep 1
    if ($api.HasExited) { throw 'Project API exited. Inspect runtime/api.err.log.' }
    try {
        $health = Invoke-RestMethod http://127.0.0.1:8000/health -TimeoutSec 2
        if ($health.ok) { $ready=$true; break }
    } catch {}
}
if (-not $ready) { throw 'Project API did not become healthy. Stop the project before retrying.' }
$apiPid = (Get-NetTCPConnection -LocalPort 8000 -State Listen | Select-Object -First 1).OwningProcess
$apiProcess = Get-Process -Id $apiPid
$records = @(@{pid=$apiProcess.Id; started=$apiProcess.StartTime.ToUniversalTime().ToString('o'); kind='api'})
ConvertTo-Json -InputObject @($records) | Set-Content "$runtime\processes.json"
$ui = Start-Process $node -ArgumentList @('node_modules/vite/bin/vite.js','--host','127.0.0.1','--port','5173','--strictPort') -WorkingDirectory $front -WindowStyle Hidden -PassThru -RedirectStandardOutput "$runtime\ui.out.log" -RedirectStandardError "$runtime\ui.err.log"
$records += @{pid=$ui.Id; started=$ui.StartTime.ToUniversalTime().ToString('o'); kind='ui'}
ConvertTo-Json -InputObject @($records) | Set-Content "$runtime\processes.json"
$ready=$false
for ($i=0; $i -lt 30; $i++) {
    Start-Sleep 1
    if ($ui.HasExited) { throw 'Project frontend exited. Inspect runtime/ui.err.log.' }
    try {
        $response=Invoke-WebRequest http://127.0.0.1:5173 -UseBasicParsing -TimeoutSec 2
        if ($response.StatusCode -eq 200) { $ready=$true; break }
    } catch {}
}
if (-not $ready) { throw 'Project frontend did not become ready.' }
Write-Output 'Project UI: http://127.0.0.1:5173; API docs: http://127.0.0.1:8000/api/v1/docs'
if ($AllowUnconfigured) { Write-Warning 'Model/OCR credentials still require live verification.' }
if (-not $NoBrowser) { Start-Process 'http://127.0.0.1:5173' }
