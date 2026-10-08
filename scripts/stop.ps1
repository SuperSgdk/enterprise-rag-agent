$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$recordPath = Join-Path $root 'runtime\processes.json'
if (Test-Path $recordPath) {
    $records = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
    foreach ($record in $records) {
        $managedProcess = Get-Process -Id $record.pid -ErrorAction SilentlyContinue
        if ($managedProcess) {
            if ($managedProcess.StartTime.ToUniversalTime() -ne ([datetime]$record.started).ToUniversalTime()) {
                throw 'Process identity changed; refusing to stop it.'
            }
            $command = (Get-CimInstance Win32_Process -Filter "ProcessId=$($record.pid)").CommandLine
            if (($record.kind -eq 'api' -and $command -notmatch 'uvicorn.*app.main:app') -or
                ($record.kind -eq 'ui' -and $command -notmatch 'vite/bin/vite.js')) {
                throw 'Process command does not match the managed project.'
            }
            Stop-Process -Id $record.pid
        }
    }
    Remove-Item -LiteralPath $recordPath
}
$docker = (Get-Command docker -ErrorAction Stop).Source
& $docker compose --env-file "$root\deploy\.env" -f "$root\deploy\compose.yml" stop
if ($LASTEXITCODE -ne 0) { throw 'Could not stop project containers.' }
Write-Output 'Project project stopped; all data retained.'
