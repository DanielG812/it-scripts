# Repair-Breeze.ps1
# Repara el registro de servicios del agente Breeze (Windows) usando la instalacion existente.
# Uso:  powershell -ExecutionPolicy Bypass -File Repair-Breeze.ps1 [-CheckOnly]
# -CheckOnly: solo diagnostica, no cambia nada.
param([switch]$CheckOnly)
$ErrorActionPreference = 'Continue'

$dir   = 'C:\Program Files\Breeze'
$agent = "$dir\breeze-agent.exe"
$wd    = "$dir\breeze-watchdog.exe"
$data  = 'C:\ProgramData\Breeze'
$log   = "$data\logs\agent.log"
$bak   = 'C:\Breeze-Recovery'
function Say($m) { Write-Host ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m) }

function Run {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = $id.IsSystem -or (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { Say 'Ejecuta como administrador o SYSTEM.'; return }

    $hasAgent = Test-Path $agent
    $hasYaml  = Test-Path "$data\agent.yaml"
    $hasSec   = Test-Path "$data\secrets.yaml"
    $svc      = Get-Service BreezeAgent, BreezeWatchdog -ErrorAction SilentlyContinue
    $procs    = Get-Process -Name 'breeze-*' -ErrorAction SilentlyContinue
    Say "Equipo $env:COMPUTERNAME | agent.exe=$hasAgent | agent.yaml=$hasYaml | secrets.yaml=$hasSec"
    Say ('Servicios: ' + $(if ($svc) { ($svc | ForEach-Object { "$($_.Name)=$($_.Status)" }) -join ', ' } else { 'ninguno registrado' }))
    Say ('Procesos: ' + $(if ($procs) { ($procs | ForEach-Object { "$($_.Name)#$($_.Id)" }) -join ', ' } else { 'ninguno' }))

    $a = $svc | Where-Object Name -eq 'BreezeAgent'
    if ($a -and $a.Status -eq 'Running' -and (Test-Path $log) -and (Get-Item $log).LastWriteTime -gt (Get-Date).AddMinutes(-5)) {
        Say 'Agente sano (en ejecucion y escribiendo log). No se toca nada.'; return
    }
    if ($CheckOnly) { Say 'Modo -CheckOnly: no se realizaron cambios.'; return }
    if (-not ($hasYaml -and $hasSec -and $hasAgent)) {
        Say 'FALTAN archivos. Restauralos desde la cuarentena de GravityZone y vuelve a ejecutar.'; return
    }
    Say ('Version: ' + (& $agent version))

    New-Item $bak -ItemType Directory -Force | Out-Null
    icacls $bak /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    Copy-Item "$data\agent.yaml", "$data\secrets.yaml" $bak -Force

    Say 'Deteniendo servicios y procesos de Breeze...'
    Get-Service BreezeWatchdog, BreezeAgent -ErrorAction SilentlyContinue | Stop-Service -Force -ErrorAction SilentlyContinue
    Get-Process -Name 'breeze-*' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep 3

    Say 'Retirando registros de servicio anteriores...'
    foreach ($e in $agent, $wd) { if (Test-Path $e) { try { & $e service uninstall *> $null } catch {} } }
    foreach ($n in 'BreezeAgent', 'BreezeWatchdog') {
        if (Get-Service $n -ErrorAction SilentlyContinue) { sc.exe delete $n | Out-Null }
    }
    Start-Sleep 3
    if (Get-Service BreezeAgent, BreezeWatchdog -ErrorAction SilentlyContinue) {
        Say 'Quedaron servicios marcados para eliminar. Reinicia el equipo y vuelve a ejecutar el script.'; return
    }

    Say 'Registrando servicios (service install --watchdog)...'
    & $agent service install --watchdog
    if ($LASTEXITCODE -ne 0) { Say "service install fallo (codigo $LASTEXITCODE). Revisa Threats Xplorer en GravityZone para este equipo."; return }
    foreach ($n in 'BreezeAgent', 'BreezeWatchdog') {
        $s = Get-Service $n -ErrorAction SilentlyContinue
        if ($s -and $s.Status -ne 'Running') { Start-Service $n -ErrorAction SilentlyContinue }
    }

    $ok = $false
    foreach ($i in 1..18) {
        Start-Sleep 5
        $s = Get-Service BreezeAgent -ErrorAction SilentlyContinue
        if ($s -and $s.Status -eq 'Running' -and (Test-Path $log) -and
            (Get-Content $log -Tail 60 | Select-String 'msg=connected component=websocket' -Quiet) -and
            (Get-Item $log).LastWriteTime -gt (Get-Date).AddMinutes(-2)) { $ok = $true; break }
    }
    if ($ok) { Say 'LISTO: agente en ejecucion y conectado. Confirma "En linea" en Breeze.' }
    else     { Say 'SIN CONFIRMAR. Ultimas lineas del log:'; Get-Content $log -Tail 15 }
    Get-Service BreezeAgent, BreezeWatchdog -ErrorAction SilentlyContinue | Format-Table Name, Status, StartType -AutoSize
}

Start-Transcript -Path 'C:\Windows\Temp\Repair-Breeze.log' -Append | Out-Null
try { Run } finally { Stop-Transcript | Out-Null }
