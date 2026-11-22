<#
.SYNOPSIS
  GPU-hőmérséklet alapú, oldalankénti ventilátorvezérlés - IBM/Lenovo System x3650 M5 (IMM2) + 2x Tesla V100.

.DESCRIPTION
  Az IMM2 gyári szabályozása nem látja a passzív Tesla GPU-k hőmérsékletét. Ez a script az
  nvidia-smi-ből olvassa a GPU-k hőmérsékletét, és oldalanként emeli a ventilátorok fordulatát
  az IMM2 OEM IPMI parancsával (NetFn 0x3A, Cmd 0x07).

  Mért elrendezés (ZoneProbe, 2026-11-22):
     1. zóna = Fan 1-3  -> CPU1 oldal: GPU 0 (busz 07:00.0, 1-es riser), CPU1 VR, DIMM AB/CD
     2. zóna = Fan 4-6  -> CPU2 oldal: GPU 1 (busz 87:00.0, 2-es riser), CPU2 VR, DIMM EF/GH
  A GPU -> zóna hozzárendelés a PCI buszszámból: busz < 0x80 -> CPU1 (1. zóna), különben 2. zóna.

  Szabályozás zónánként:
   - Hideg oldalon a gyári (IMM) automatika marad.
   - A saját GPU görbéje szerint emel; a másik oldal forró GPU-ja kisebb mértékben (CrossPercent-tel
     kevesebbet) szintén emeli, a középső átszívás miatt.
   - Átvételkor megjegyzi a zóna gyári fordulatát; ennél lassabbra nem állít.
   - 100 %: saját GPU >= GpuPanicTemp, saját CPU VR / DIMM VR túlmelegedés, PCH túlmelegedés
     (mindkét zóna), GPU vagy ventilátor nem olvasható.
   - Kilépéskor visszaadja a gyári automatikát.

  Kommunikáció: in-band, a Windows IPMI driverén át (WMI Microsoft_IPMI); nem kell hálózat
  vagy IMM jelszó. Rendszergazda / SYSTEM jog szükséges.

.PARAMETER Mode
  Status    - kiolvasás, semmit nem állít
  Run       - folyamatos szabályozás (előtérben vagy a háttérfeladatból)
  Restore   - gyári automatika visszaállítása
  ZoneProbe - zónák ellenőrzése (zónánként 100 % 45 s-ig, majd vissza)
  Install   - háttérfeladat telepítése (SYSTEM, gépindításkor, felügyelt újraindítással) és indítása
  Uninstall - háttérfeladat leállítása és eltávolítása, gyári automatika visszaállítása
  Start     - háttérfeladat engedélyezése és indítása
  Stop      - háttérfeladat szabályos leállítása (gyári automatika visszaáll) és letiltása

.EXAMPLE
  .\LenovoGpuFanControl.ps1 -Mode Install
  .\LenovoGpuFanControl.ps1 -Mode Status
  .\LenovoGpuFanControl.ps1 -Mode Stop
#>
[CmdletBinding()]
param(
    [ValidateSet('Status', 'Run', 'Restore', 'ZoneProbe', 'Install', 'Uninstall', 'Start', 'Stop', 'Watchdog')]
    [string]$Mode = 'Status',
    [int]$IntervalSec = 5,
    [int]$EngageTemp = 52,                          # saját GPU ennél melegebb -> az oldal kézi vezérlésre vált
    [int]$ReleaseTemp = 47,                         # ez alatt (ReleaseHoldSec ideig) -> vissza gyári automatikára
    [int]$ReleaseHoldSec = 120,
    [string]$Curve = '52:40,58:50,64:65,70:80,75:100',   # GPU °C : ventilátor %, lineáris interpoláció
    [int]$CrossPercent = 35,                       # a másik oldal GPU-ja ennyivel kisebb %-ot kér erre az oldalra
    [int]$MinPercent = 30,
    [int]$StepDownPercent = 3,                      # csökkentés max %/ciklus (növelés azonnali)
    [int]$CpuVrMaxTemp = 70,
    [int]$DimmVrMaxTemp = 75,
    [int]$PchMaxTemp = 80,
    [int]$GpuPanicTemp = 82,
    [int]$LogEverySec = 60,                         # normál állapotsor gyakorisága a naplóban
    [int]$LogKeepDays = 14,
    [string]$LogDir = '',
    [int]$ExpectedGpus = 2,                         # ennyi GPU-nak kell látszania, és minden zónában legyen legalább egy
    [int]$SensorFailCycles = 3,                     # ennyi egymást követő ciklusban hiányzó védelmi szenzor -> 100 %
    [int]$IpmiFailLimit = 12,                       # ennyi egymást követő IPMI-hiba -> kilépés (felügyelet újraindít)
    [int]$HeartbeatStaleSec = 90,                   # watchdog: ennél régebbi életjel -> beavatkozás
    [string[]]$Simulate = @(),                      # csak teszteléshez: GpuFail, GpuMissing, SensorMissing, IpmiSetFail, Hang
    [int]$AutoSettleSec = 90,                       # ennyi ideje automatikán lévő oldal fordulata számít gyári értéknek
    [int]$IdleAutoRpm = 4000,                       # mért gyári üresjárati fordulat (alsó határ, ha nincs beállt mérés)
    [int]$MaxCycles = 0                            # csak teszteléshez: ennyi ciklus után kilép (0 = végtelen)
)

$ErrorActionPreference = 'Stop'
$TaskName = 'LenovoGpuFanControl'
$ScriptPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$Root = Split-Path -Parent $ScriptPath
if (-not $LogDir) { $LogDir = Join-Path $Root 'logs' }
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$StopFile = Join-Path $Root 'fan_stop.flag'
$HeartbeatFile = Join-Path $Root 'fan_heartbeat.txt'
$WatchdogTaskName = 'LenovoGpuFanControl-Watchdog'
$Simulate = @($Simulate | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$bad = @($Simulate | Where-Object { $_ -notin 'GpuFail', 'GpuMissing', 'SensorMissing', 'IpmiSetFail', 'Hang' })
if ($bad.Count) { throw "Ismeretlen -Simulate érték: $($bad -join ', ')" }
if ($Simulate.Count -and $Mode -ne 'Run') { throw '-Simulate csak -Mode Run mellett használható.' }

$ZoneDef = @(
    [pscustomobject]@{ Id = 1; Label = 'Z1 (CPU1, ventilátor 1-3)'; FanRe = '^Fan [1-3][AB] '
        CpuVr = @('CPU1 VR Temp'); DimmVr = @('DIMM AB VR Temp', 'DIMM CD VR Temp') }
    [pscustomobject]@{ Id = 2; Label = 'Z2 (CPU2, ventilátor 4-6)'; FanRe = '^Fan [4-6][AB] '
        CpuVr = @('CPU2 VR Temp'); DimmVr = @('DIMM EF VR Temp', 'DIMM GH VR Temp') }
)

# ---------------------------------------------------------------------------
# Naplózás (Run módban napi fájl)
# ---------------------------------------------------------------------------
$script:fixedLog = Join-Path $LogDir ("fan_{0}_{1}.txt" -f $Mode.ToLower(), (Get-Date -Format 'yyyyMMdd_HHmmss'))
function Get-LogFile {
    if ($Mode -eq 'Run' -and -not $Simulate.Count -and -not $MaxCycles) { Join-Path $LogDir ("fan_run_{0}.txt" -f (Get-Date -Format 'yyyyMMdd')) }
    elseif ($Mode -eq 'Watchdog') { Join-Path $LogDir ("fan_watchdog_{0}.txt" -f (Get-Date -Format 'yyyyMMdd')) }
    else { $script:fixedLog }
}
function Write-Heartbeat {
    try { Set-Content -Path $HeartbeatFile -Value "$PID|$((Get-Date).ToString('o'))" -Encoding ASCII } catch {}
}
function Write-Log([string]$msg = '') {
    $line = if ($msg) { "$(Get-Date -Format 'HH:mm:ss')  $msg" } else { '' }
    Write-Host $line
    try { Add-Content -Path (Get-LogFile) -Value $line -Encoding UTF8 } catch {}
}
function Remove-OldLogs {
    Get-ChildItem $LogDir -File -Filter 'fan_*' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$LogKeepDays) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# IPMI (WMI Microsoft_IPMI)
# ---------------------------------------------------------------------------
$script:ipmi = $null

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Initialize-Ipmi {
    if (-not (Test-Admin)) { throw 'Rendszergazdai PowerShell szükséges.' }
    $script:ipmi = Get-CimInstance -Namespace root/wmi -ClassName Microsoft_IPMI | Select-Object -First 1
    if (-not $script:ipmi) { throw 'Microsoft_IPMI nem érhető el (IPMI driver?)' }
}

function Invoke-Ipmi([byte]$NetFn, [byte]$Cmd, [byte[]]$Data = @()) {
    # Engedélyezett: olvasó parancsok + az OEM ventilátorparancs (0x3A/0x07)
    $allowed = @('6:1', '10:32', '10:34', '10:35', '4:45', '58:7')
    if ($allowed -notcontains "$NetFn`:$Cmd") { throw "Nem engedélyezett IPMI parancs: NetFn $NetFn Cmd $Cmd" }
    $req = if ($Data.Count -gt 0) { $Data } else { [byte[]]@(0) }
    $r = Invoke-CimMethod -InputObject $script:ipmi -MethodName RequestResponse -Arguments @{
        Command = $Cmd; Lun = [byte]0; NetworkFunction = $NetFn; ResponderAddress = [byte]0x20
        RequestData = [byte[]]$req; RequestDataSize = [uint32]$Data.Count
    }
    $resp = [byte[]]$r.ResponseData
    if ($null -eq $resp -or $resp.Count -lt 1) { throw "Üres IPMI válasz (NetFn $NetFn Cmd $Cmd)" }
    if ($resp[0] -ne 0) { throw ("IPMI completion code 0x{0:X2} (NetFn 0x{1:X2} Cmd 0x{2:X2})" -f $resp[0], $NetFn, $Cmd) }
    return $resp
}

function Convert-Signed([int]$v, [int]$bits) { if ($v -band (1 -shl ($bits - 1))) { $v - (1 -shl $bits) } else { $v } }

function Get-SensorList {
    $resv = Invoke-Ipmi 10 34
    $r0, $r1 = $resv[1], $resv[2]
    $get = {
        param($id, $off, $cnt)
        Invoke-Ipmi 10 35 ([byte[]]@($r0, $r1, ($id -band 0xFF), ($id -shr 8), $off, $cnt))
    }
    $list = @(); $recId = 0; $seen = @{}
    while ($recId -ne 0xFFFF -and -not $seen.ContainsKey($recId) -and $seen.Count -lt 1000) {
        $seen[$recId] = $true
        $h = & $get $recId 0 5
        $next = $h[1] + ($h[2] -shl 8)
        $hdr = $h[3..7]; $len = $hdr[4]
        $body = New-Object System.Collections.Generic.List[byte]
        $off = 5
        while ($body.Count -lt $len) {
            $n = [math]::Min(16, $len - $body.Count)
            $c = & $get $recId $off $n
            $body.AddRange([byte[]]$c[3..($c.Count - 1)]); $off += $n
        }
        $rec = [byte[]]($hdr + $body.ToArray())
        if ($hdr[3] -eq 1 -and $rec.Count -ge 48 -and $rec[5] -eq 0x20) {
            $idLen = $rec[47] -band 0x1F
            $list += [pscustomobject]@{
                Num = $rec[7]; Type = $rec[12]; Fmt = ($rec[20] -shr 6); Unit = $rec[21]
                M = Convert-Signed ($rec[24] + (($rec[25] -band 0xC0) -shl 2)) 10
                B = Convert-Signed ($rec[26] + (($rec[27] -band 0xC0) -shl 2)) 10
                RExp = Convert-Signed ($rec[29] -shr 4) 4; BExp = Convert-Signed ($rec[29] -band 0x0F) 4
                Name = [Text.Encoding]::ASCII.GetString($rec, 48, [math]::Min($idLen, $rec.Count - 48)).Trim([char]0, ' ')
            }
        }
        $recId = $next
    }
    return $list | Sort-Object Num -Unique
}

function Read-Sensor($s) {
    try { $r = Invoke-Ipmi 4 45 ([byte[]]@($s.Num)) } catch { return $null }
    if ($r.Count -ge 3 -and ($r[2] -band 0x20)) { return $null }
    $x = [int]$r[1]
    if ($s.Fmt -eq 1) { $x = Convert-Signed $x 8; if ($x -lt 0) { $x += 1 } }
    elseif ($s.Fmt -eq 2) { $x = Convert-Signed $x 8 }
    return ($s.M * $x + $s.B * [math]::Pow(10, $s.BExp)) * [math]::Pow(10, $s.RExp)
}

function Get-MaxOf($values) {
    $v = @($values | Where-Object { $null -ne $_ })
    if ($v.Count) { ($v | Measure-Object -Maximum).Maximum } else { $null }
}

function Read-Board {
    $fans = @{}; $temps = @{}
    foreach ($s in $script:fanSensors) { $v = Read-Sensor $s; if ($null -ne $v) { $fans[$s.Name] = [int]$v } }
    foreach ($s in $script:tempSensors) { $v = Read-Sensor $s; if ($null -ne $v) { $temps[$s.Name] = [int]$v } }
    if ($Simulate -contains 'SensorMissing') { $temps.Remove('CPU1 VR Temp') }
    $zones = @{}
    foreach ($z in $ZoneDef) {
        $zf = @($fans.Keys | Where-Object { $_ -match $z.FanRe } | ForEach-Object { $fans[$_] })
        $need = @($z.CpuVr + $z.DimmVr + 'PCH Temp')
        $zones[$z.Id] = [pscustomobject]@{
            FanAvg = $(if ($zf.Count) { [int](($zf | Measure-Object -Average).Average) } else { $null })
            FanCount = $zf.Count
            Missing = @($need | Where-Object { -not $temps.ContainsKey($_) })
            CpuVr = Get-MaxOf ($z.CpuVr | ForEach-Object { $temps[$_] })
            DimmVr = Get-MaxOf ($z.DimmVr | ForEach-Object { $temps[$_] })
        }
    }
    [pscustomobject]@{ Fans = $fans; Temps = $temps; Zones = $zones; Pch = $temps['PCH Temp'] }
}

function ConvertTo-FanByte([int]$pct) { [byte][math]::Max(0, [math]::Min(255, [math]::Round($pct * 255 / 100))) }
function Set-ZoneManual([int]$zone, [int]$pct) {
    if ($Simulate -contains 'IpmiSetFail') { throw 'szimulált IPMI-hiba' }
    [void](Invoke-Ipmi 0x3A 0x07 ([byte[]]@($zone, (ConvertTo-FanByte $pct), 0x01)))
}
function Set-ZoneAuto([int]$zone) { [void](Invoke-Ipmi 0x3A 0x07 ([byte[]]@($zone, 0x12, 0x00))) }
function Set-AllAuto {
    $err = $null
    foreach ($z in $ZoneDef) { try { Set-ZoneAuto $z.Id } catch { $err = $_.Exception.Message } }
    if ($err) { throw $err }
}

# ---------------------------------------------------------------------------
# GPU
# ---------------------------------------------------------------------------
function Read-Gpus {
    $smi = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
    if (-not (Test-Path $smi)) { $smi = 'nvidia-smi' }
    $out = & $smi --query-gpu=index,pci.bus_id,temperature.gpu,temperature.memory,power.draw --format=csv,noheader,nounits 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
    $list = foreach ($l in $out) {
        $v = $l -split ',\s*'
        if ($v.Count -lt 5 -or $v[2] -notmatch '^\d+$') { continue }
        $bus = [Convert]::ToInt32(($v[1] -split ':')[1], 16)
        $mem = if ($v[3] -match '^\d+$') { [int]$v[3] } else { $null }
        $t = [int]$v[2]; if ($null -ne $mem -and $mem - 5 -gt $t) { $t = $mem - 5 }
        [pscustomobject]@{ Index = [int]$v[0]; Bus = $v[1]; Zone = $(if ($bus -lt 0x80) { 1 } else { 2 })
            Temp = [int]$v[2]; Mem = $mem; Eff = $t
            Power = $(if ($v[4] -match '^[\d.]+$') { [double]$v[4] } else { $null }) }
    }
    if ($Simulate -contains 'GpuFail') { return $null }
    if ($Simulate -contains 'GpuMissing') { $list = @($list | Where-Object Zone -ne 2) }
    return @($list)
}

$script:curvePts = $Curve.Split(',') | ForEach-Object {
    $a = $_.Split(':'); [pscustomobject]@{ T = [double]$a[0]; P = [double]$a[1] }
} | Sort-Object T

function Get-CurvePercent($t) {
    if ($null -eq $t) { return 0 }
    $p = $script:curvePts
    if ($t -lt $EngageTemp) { return 0 }
    if ($t -le $p[0].T) { return [int]$p[0].P }
    for ($i = 1; $i -lt $p.Count; $i++) {
        if ($t -le $p[$i].T) {
            return [int]($p[$i - 1].P + ($p[$i].P - $p[$i - 1].P) * ($t - $p[$i - 1].T) / ($p[$i].T - $p[$i - 1].T))
        }
    }
    return [int]$p[-1].P
}

function Format-Gpus($gpus) {
    if (-not $gpus) { return 'GPU: n/a' }
    ($gpus | ForEach-Object { "GPU$($_.Index)[Z$($_.Zone)] $($_.Temp)°C/$([int]$_.Power)W" }) -join '  '
}

# ---------------------------------------------------------------------------
# Háttérfeladat kezelése
# ---------------------------------------------------------------------------
function Get-ControllerMutex {
    # $null = nem hozzáférhető (más fiók, pl. SYSTEM birtokolja)
    try {
        # SYSTEM és rendszergazdák egyaránt elérjék (háttérfeladat <-> rendszergazdai ablak)
        $sec = New-Object System.Security.AccessControl.MutexSecurity
        foreach ($sid in 'S-1-5-18', 'S-1-5-32-544') {
            $id = New-Object System.Security.Principal.SecurityIdentifier($sid)
            $sec.AddAccessRule((New-Object System.Security.AccessControl.MutexAccessRule($id,
                [System.Security.AccessControl.MutexRights]::FullControl, [System.Security.AccessControl.AccessControlType]::Allow)))
        }
        $created = $false
        return New-Object System.Threading.Mutex($false, 'Global\LenovoGpuFanControl', [ref]$created, $sec)
    } catch { return $null }
}

function Test-ControllerRunning {
    $m = Get-ControllerMutex
    if (-not $m) { return $true }
    $free = $false
    try { $free = $m.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $free = $true }
    if ($free) { $m.ReleaseMutex() }
    $m.Dispose()
    return -not $free
}

function Wait-RunExit([int]$sec) {
    $t0 = Get-Date
    do {
        if (-not (Test-ControllerRunning)) { return $true }
        Start-Sleep 1
    } while (((Get-Date) - $t0).TotalSeconds -lt $sec)
    return $false
}

function Stop-Controller {
    foreach ($tn in $WatchdogTaskName, $TaskName) {
        if (Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue) { Disable-ScheduledTask -TaskName $tn | Out-Null }
    }
    New-Item -ItemType File -Force -Path $StopFile | Out-Null
    Write-Host 'Leállítási jelzés elküldve, várakozás a vezérlő kilépésére...'
    $ok = Wait-RunExit 40
    if (-not $ok -and (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Start-Sleep 2
    }
    Remove-Item $StopFile -Force -ErrorAction SilentlyContinue
    Initialize-Ipmi
    Set-AllAuto
    Write-Host $(if ($ok) { 'A vezérlő leállt; gyári automatika visszaállítva.' }
                 else { 'A vezérlő nem lépett ki időben, leállítva; gyári automatika visszaállítva.' })
}

switch ($Mode) {
    'Install' {
        if (-not (Test-Admin)) { throw 'Rendszergazdai PowerShell szükséges.' }
        $arg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`" -Mode Run"
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg -WorkingDirectory $Root
        $triggers = @(
            (New-ScheduledTaskTrigger -AtStartup),
            # felügyelet: ha a vezérlő bármiért kilépett, 5 percen belül újraindul (futó példány mellett nem indul új)
            (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5))
        )
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
            -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
            -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers -Principal $principal `
            -Settings $settings -Description 'GPU-hőmérséklet alapú oldalankénti ventilátorvezérlés (IMM2)' -Force | Out-Null
        # független watchdog: percenként ellenőrzi az életjelet; lefagyott vezérlőt leállít, gyári automatikát állít, újraindít
        $wdArg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`" -Mode Watchdog"
        $wdAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $wdArg -WorkingDirectory $Root
        $wdTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)
        $wdSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 3) -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName $WatchdogTaskName -Action $wdAction -Trigger $wdTrigger -Principal $principal `
            -Settings $wdSettings -Description 'Watchdog a LenovoGpuFanControl vezérlőhöz' -Force | Out-Null
        Remove-Item $StopFile -Force -ErrorAction SilentlyContinue
        Start-ScheduledTask -TaskName $TaskName
        Write-Host "Háttérfeladat telepítve és elindítva: $TaskName (SYSTEM, gépindításkor + 5 percenkénti felügyelet)"
        Write-Host "Watchdog telepítve: $WatchdogTaskName (percenként, életjel > $HeartbeatStaleSec s -> beavatkozás)"
        Write-Host "Napló: $LogDir\fan_run_<dátum>.txt / .csv"
        return
    }
    'Uninstall' {
        if (-not (Test-Admin)) { throw 'Rendszergazdai PowerShell szükséges.' }
        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
            Stop-Controller
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            Write-Host "Háttérfeladat eltávolítva: $TaskName"
        } else { Write-Host 'A háttérfeladat nincs telepítve.' }
        if (Get-ScheduledTask -TaskName $WatchdogTaskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $WatchdogTaskName -Confirm:$false
            Write-Host "Watchdog eltávolítva: $WatchdogTaskName"
        }
        Remove-Item $HeartbeatFile -Force -ErrorAction SilentlyContinue
        return
    }
    'Watchdog' {
        if (-not (Test-Path $HeartbeatFile)) { return }      # tiszta leállás, vagy még nem indult el
        $hbPid = 0; $hbTime = [datetime]::MinValue
        try {
            $parts = (Get-Content $HeartbeatFile -Raw).Trim() -split '\|'
            $hbPid = [int]$parts[0]; $hbTime = [datetime]::Parse($parts[1], $null, [Globalization.DateTimeStyles]::RoundtripKind)
        } catch {}
        $age = [int]((Get-Date) - $hbTime).TotalSeconds
        if ($age -lt $HeartbeatStaleSec) { return }
        Write-Log "WATCHDOG: az életjel $age s régi (PID $hbPid) - a vezérlő lefagyott vagy váratlanul leállt"
        $proc = Get-Process -Id $hbPid -ErrorAction SilentlyContinue
        if ($proc -and $proc.ProcessName -eq 'powershell') {
            try { Stop-Process -Id $hbPid -Force; Write-Log "WATCHDOG: lefagyott vezérlő (PID $hbPid) leállítva" }
            catch { Write-Log "WATCHDOG: a folyamat nem állítható le: $($_.Exception.Message)" }
            Start-Sleep 2
        }
        try { Initialize-Ipmi; Set-AllAuto; Write-Log 'WATCHDOG: gyári automatika visszaállítva (mindkét zóna)' }
        catch { Write-Log "WATCHDOG: az automatika visszaállítása SIKERTELEN: $($_.Exception.Message)" }
        Remove-Item $HeartbeatFile -Force -ErrorAction SilentlyContinue
        $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($t -and $t.State -ne 'Disabled') {
            try { Start-ScheduledTask -TaskName $TaskName; Write-Log 'WATCHDOG: vezérlő újraindítva' }
            catch { Write-Log "WATCHDOG: újraindítás sikertelen: $($_.Exception.Message)" }
        }
        return
    }
    'Start' {
        if (-not (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) { throw 'Nincs telepítve (-Mode Install).' }
        Remove-Item $StopFile -Force -ErrorAction SilentlyContinue
        Enable-ScheduledTask -TaskName $TaskName | Out-Null
        if (Get-ScheduledTask -TaskName $WatchdogTaskName -ErrorAction SilentlyContinue) {
            Enable-ScheduledTask -TaskName $WatchdogTaskName | Out-Null
        }
        Start-ScheduledTask -TaskName $TaskName
        Write-Host 'Háttérfeladat elindítva.'
        return
    }
    'Stop' {
        if (-not (Test-Admin)) { throw 'Rendszergazdai PowerShell szükséges.' }
        Stop-Controller
        Write-Host "A háttérfeladat letiltva; újraindítás: -Mode Start"
        return
    }
}

# ---------------------------------------------------------------------------
# IMM-et használó módok
# ---------------------------------------------------------------------------
$script:mutex = $null
if ($Mode -in 'Run', 'ZoneProbe') {
    $script:mutex = Get-ControllerMutex
    $got = $false
    if ($script:mutex) {
        try { $got = $script:mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $got = $true }
    }
    if (-not $got) {
        Write-Host 'Már fut egy vezérlő példány (valószínűleg a háttérfeladat). Leállítás: -Mode Stop'
        exit 2
    }
}

if ($Mode -eq 'Run') { Write-Heartbeat }
Write-Log "Lenovo GPU ventilátorvezérlés - mód: $Mode$(if ($Mode -eq 'Run') { ", felhasználó: $env:USERNAME" })$(if ($Simulate.Count) { ", SZIMULÁCIÓ: $($Simulate -join ',')" })"
try {
    Initialize-Ipmi
    Write-Log 'Szenzorlista beolvasása az IMM2-ből...'
    $all = Get-SensorList
    $script:fanSensors = @($all | Where-Object { $_.Unit -eq 18 -and $_.Name -notlike '*Riser*' })
    $script:tempSensors = @($all | Where-Object { $_.Unit -eq 1 })
    Write-Log "  $($script:fanSensors.Count) ventilátor-, $($script:tempSensors.Count) hőmérséklet-szenzor"

    switch ($Mode) {

        'Status' {
            $g = Read-Gpus; $b = Read-Board
            $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            Write-Log "Háttérfeladat: $(if ($task) { "$($task.State)" } else { 'nincs telepítve' })"
            Write-Log (Format-Gpus $g)
            foreach ($z in $ZoneDef) {
                $zs = $b.Zones[$z.Id]
                Write-Log ("{0}: vent. átl. {1} RPM, CPU VR {2} °C, DIMM VR {3} °C" -f $z.Label, $zs.FanAvg, $zs.CpuVr, $zs.DimmVr)
            }
            Write-Log "PCH $($b.Pch) °C"
            foreach ($k in ($b.Fans.Keys | Sort-Object)) { Write-Log ("   {0,-14} {1} RPM" -f $k, $b.Fans[$k]) }
            foreach ($k in ($b.Temps.Keys | Sort-Object)) { Write-Log ("   {0,-18} {1} °C" -f $k, $b.Temps[$k]) }
        }

        'Restore' {
            if (Test-ControllerRunning) { Write-Log 'FIGYELEM: a vezérlő fut, 30 s-on belül újra átveszi. Leállítás: -Mode Stop' }
            Set-AllAuto
            Write-Log 'Gyári automatikus vezérlés visszaállítva (mindkét zóna).'
        }

        'ZoneProbe' {
            try {
                foreach ($z in $ZoneDef) {
                    Write-Log ''
                    Write-Log "=== $($z.Label) 100 % ==="
                    $b0 = Read-Board; $g0 = Read-Gpus
                    Set-ZoneManual $z.Id 100
                    Start-Sleep 45
                    $b1 = Read-Board; $g1 = Read-Gpus
                    foreach ($zz in $ZoneDef) {
                        Write-Log ("  {0}: {1} -> {2} RPM" -f $zz.Label, $b0.Zones[$zz.Id].FanAvg, $b1.Zones[$zz.Id].FanAvg)
                    }
                    foreach ($gg in $g1) {
                        $before = ($g0 | Where-Object Index -eq $gg.Index).Temp
                        Write-Log ("  GPU{0}[Z{1}]: {2} -> {3} °C" -f $gg.Index, $gg.Zone, $before, $gg.Temp)
                    }
                    Set-ZoneAuto $z.Id
                    Write-Log '  vissza automatára, 60 s...'
                    Start-Sleep 60
                }
            } finally { try { Set-AllAuto } catch {} }
        }

        'Run' {
            Remove-OldLogs
            Remove-Item $StopFile -Force -ErrorAction SilentlyContinue
            try { Set-AllAuto } catch { Write-Log "FIGYELEM: kezdeti automatika-visszaállítás: $($_.Exception.Message)" }
            Write-Log "Görbe: $Curve (°C:%), átvétel >= $EngageTemp °C, visszaadás < $ReleaseTemp °C ($ReleaseHoldSec s), másik oldal -$CrossPercent %"
            $state = @{}
            foreach ($z in $ZoneDef) {
                $state[$z.Id] = [pscustomobject]@{ Manual = $false; Pct = 0; Floor = 0; MinPct = $MinPercent
                    CoolSince = $null; LastSend = [datetime]::MinValue; LastChange = [datetime]::MinValue
                    SensorMiss = 0; IpmiFail = 0; AutoSince = Get-Date }
            }
            $lastLog = [datetime]::MinValue; $lastDay = (Get-Date).Date; $cycle = 0
            try {
                while (-not (Test-Path $StopFile) -and ($MaxCycles -le 0 -or $cycle -lt $MaxCycles)) {
                    $cycle++
                    Write-Heartbeat
                    if ($Simulate -contains 'Hang' -and $cycle -gt 3) {
                        Write-Log 'SZIMULÁCIÓ: lefagyás (a watchdognak kell beavatkoznia)'
                        Start-Sleep 3600
                    }
                    if ((Get-Date).Date -ne $lastDay) { Remove-OldLogs; $lastDay = (Get-Date).Date }
                    $gr = Read-Gpus
                    $g = $null
                    if ($null -ne $gr) { $g = @($gr) }      # mindig tömb, 1 GPU esetén is (közvetlen értékadás!)
                    $b = Read-Board
                    $gpuT = @{ 1 = $null; 2 = $null }
                    foreach ($x in $g) { $gpuT[$x.Zone] = Get-MaxOf @($gpuT[$x.Zone], $x.Eff) }
                    $logNow = $false; $parts = @()

                    # elvárt GPU-k: darabszám + minden zónában legalább egy; hiba esetén MINDKÉT zóna 100 %
                    $gpuFault = ''
                    if ($null -eq $g -or $g.Count -eq 0) { $gpuFault = 'GPU-lekérdezés sikertelen' }
                    elseif ($g.Count -lt $ExpectedGpus) { $gpuFault = "csak $($g.Count)/$ExpectedGpus GPU látható" }
                    else {
                        $empty = @($ZoneDef | Where-Object { $zid = $_.Id; -not ($g | Where-Object Zone -eq $zid) } | ForEach-Object { "Z$($_.Id)" })
                        if ($empty.Count) { $gpuFault = "nincs GPU: $($empty -join ',')" }
                    }

                    foreach ($z in $ZoneDef) {
                        $s = $state[$z.Id]; $zs = $b.Zones[$z.Id]
                        $tOwn = $gpuT[$z.Id]; $tOther = $gpuT[3 - $z.Id]
                        $cOwn = Get-CurvePercent $tOwn
                        # hiszterézis-sáv (ReleaseTemp..EngageTemp) kézi módban: a görbe első pontja
                        if ($s.Manual -and $null -ne $tOwn -and $tOwn -ge $ReleaseTemp -and $cOwn -eq 0) {
                            $cOwn = [int]$script:curvePts[0].P
                        }
                        $cOther = (Get-CurvePercent $tOther) - $CrossPercent
                        if ($cOther -le $MinPercent) { $cOther = 0 }
                        $target = [math]::Max($cOwn, $cOther)
                        $reason = ''
                        if ($gpuFault) { $target = 100; $reason = $gpuFault }
                        # hiányzó védelmi szenzor (CPU VR, DIMM VR, PCH) tartósan -> 100 %
                        if ($zs.Missing.Count) { $s.SensorMiss++ } else { $s.SensorMiss = 0 }
                        if ($s.SensorMiss -ge $SensorFailCycles) { $target = 100; $reason = "szenzor nem olvasható: $($zs.Missing -join ', ')" }
                        if ($s.IpmiFail -gt 0) { $target = 100; $reason = "IPMI-hiba ($($s.IpmiFail)x)" }
                        if ($null -ne $tOwn -and $tOwn -ge $GpuPanicTemp) { $target = 100; $reason = "GPU >= $GpuPanicTemp °C" }
                        if ($null -ne $zs.CpuVr -and $zs.CpuVr -ge $CpuVrMaxTemp) { $target = 100; $reason = "CPU VR $($zs.CpuVr) °C" }
                        if ($null -ne $zs.DimmVr -and $zs.DimmVr -ge $DimmVrMaxTemp) { $target = 100; $reason = "DIMM VR $($zs.DimmVr) °C" }
                        if ($null -ne $b.Pch -and $b.Pch -ge $PchMaxTemp) { $target = 100; $reason = "PCH $($b.Pch) °C" }
                        if (-not $zs.FanAvg) { $target = 100; $reason = 'ventilátor nem olvasható' }

                        if (-not $s.Manual -and $target -gt 0) {
                            $s.Manual = $true; $s.Pct = 0; $s.CoolSince = $null; $s.MinPct = $MinPercent
                            # gyári fordulat csak beállt automatikából mérhető; különben a gyári üresjárati érték
                            $settled = ((Get-Date) - $s.AutoSince).TotalSeconds -ge $AutoSettleSec
                            $s.Floor = if ($settled -and $zs.FanAvg) { $zs.FanAvg } else { $IdleAutoRpm }
                            Write-Log ("ÁTVÉTEL {0}: saját GPU {1} °C, másik {2} °C, gyári alsó határ {3} RPM{4}{5}" -f
                                $z.Label, $tOwn, $tOther, $s.Floor, $(if (-not $settled) { ' (üresjárati érték, az automatika még nem állt be)' } else { '' }),
                                $(if ($reason) { " [$reason]" } else { '' }))
                            $logNow = $true
                        }

                        if ($s.Manual) {
                            $target = [math]::Max($target, $s.MinPct)
                            # sosem lassabb, mint a gyári fordulat átvételkor (beállás után ellenőrizve)
                            if ($zs.FanAvg -and $s.Pct -gt 0 -and $s.Pct -lt 100 -and ((Get-Date) - $s.LastChange).TotalSeconds -ge 20 -and
                                $zs.FanAvg -lt $s.Floor * 0.95 -and $s.Pct -ge $target) {
                                $s.MinPct = [math]::Min(100, $s.Pct + 5); $target = $s.MinPct
                                Write-Log "$($z.Label): $($zs.FanAvg) RPM a gyári $($s.Floor) RPM alatt -> alsó határ $($s.MinPct) %"
                                $logNow = $true
                            }
                            $new = if ($target -ge $s.Pct) { $target } else { [math]::Max($target, $s.Pct - $StepDownPercent) }
                            if ($new -ne $s.Pct -or $s.IpmiFail -gt 0 -or ((Get-Date) - $s.LastSend).TotalSeconds -ge 30) {
                                $sent = $false; $primaryOk = $false
                                try { Set-ZoneManual $z.Id $new; $sent = $true; $primaryOk = $true }
                                catch {
                                    $s.IpmiFail++; $logNow = $true
                                    Write-Log "IPMI HIBA ($($z.Label), $($s.IpmiFail)/$IpmiFailLimit): $($_.Exception.Message)"
                                    if ($new -lt 100) {     # azonnali vészkísérlet 100 %-kal
                                        try { Set-ZoneManual $z.Id 100; $new = 100; $sent = $true } catch {}
                                    }
                                }
                                # a belső állapot csak sikeres IPMI-parancs után változik
                                if ($sent) {
                                    if ($primaryOk -and $s.IpmiFail -gt 0) { Write-Log "$($z.Label): IPMI helyreállt"; $s.IpmiFail = 0; $logNow = $true }
                                    if ($new -ne $s.Pct) { $s.LastChange = Get-Date }
                                    if ([math]::Abs($new - $s.Pct) -ge 10 -or $reason) { $logNow = $true }
                                    $s.Pct = $new; $s.LastSend = Get-Date
                                }
                                if ($s.IpmiFail -ge $IpmiFailLimit) {
                                    throw "tartós IPMI-hiba ($($s.IpmiFail) egymást követő sikertelen parancs, $($z.Label))"
                                }
                            }
                            $hot = $reason -or ($null -ne $tOwn -and $tOwn -ge $ReleaseTemp) -or $cOther -gt 0
                            if (-not $hot) {
                                if (-not $s.CoolSince) { $s.CoolSince = Get-Date }
                                elseif (((Get-Date) - $s.CoolSince).TotalSeconds -ge $ReleaseHoldSec) {
                                    # csak sikeres visszaállító parancs után tekintjük AUTO-nak; különben kézi marad és később újrapróbálja
                                    try {
                                        Set-ZoneAuto $z.Id
                                        $s.Manual = $false; $s.Pct = 0; $s.AutoSince = Get-Date
                                        Write-Log "VISSZAADÁS $($z.Label): saját GPU $tOwn °C -> gyári automatika"
                                    } catch {
                                        $s.CoolSince = Get-Date
                                        Write-Log "VISSZAADÁS SIKERTELEN $($z.Label): $($_.Exception.Message) - kézi vezérlés marad, újrapróbálás $ReleaseHoldSec s múlva"
                                    }
                                    $logNow = $true
                                }
                            } else { $s.CoolSince = $null }
                        }
                        $parts += ("Z{0} {1,-8} {2,5} RPM VR {3}/{4}°C{5}" -f $z.Id,
                            $(if ($s.Manual) { if ($s.IpmiFail) { 'KÉZI ?%' } else { "KÉZI $($s.Pct)%" } } else { 'AUTO' }), $zs.FanAvg, $zs.CpuVr, $zs.DimmVr,
                            $(if ($reason) { " [$reason]" } else { '' }))
                    }

                    if ($logNow -or ((Get-Date) - $lastLog).TotalSeconds -ge $LogEverySec) {
                        Write-Log ("{0} | {1} | PCH {2}°C" -f (Format-Gpus $g), ($parts -join ' | '), $b.Pch)
                        $lastLog = Get-Date
                    }
                    $csv = if ($Simulate.Count -or $MaxCycles) { [IO.Path]::ChangeExtension($script:fixedLog, 'csv') }
                           else { Join-Path $LogDir ("fan_run_{0}.csv" -f (Get-Date -Format 'yyyyMMdd')) }
                    if (-not (Test-Path $csv)) {
                        'ido,gpu0,gpu1,z1_allapot,z1_pct,z1_rpm,z2_allapot,z2_pct,z2_rpm,cpu1vr,cpu2vr,dimm1vr,dimm2vr,pch' |
                            Set-Content $csv -Encoding UTF8
                    }
                    $s1 = $state[1]; $s2 = $state[2]; $z1 = $b.Zones[1]; $z2 = $b.Zones[2]
                    $g0 = ($g | Where-Object Index -eq 0).Temp; $g1 = ($g | Where-Object Index -eq 1).Temp
                    $row = "$(Get-Date -Format s),$g0,$g1," +
                        "$(if ($s1.Manual) { 'kezi' } else { 'auto' }),$(if ($s1.Manual) { $s1.Pct }),$($z1.FanAvg)," +
                        "$(if ($s2.Manual) { 'kezi' } else { 'auto' }),$(if ($s2.Manual) { $s2.Pct }),$($z2.FanAvg)," +
                        "$($z1.CpuVr),$($z2.CpuVr),$($z1.DimmVr),$($z2.DimmVr),$($b.Pch)"
                    try { Add-Content $csv $row -Encoding UTF8 } catch {}
                    Start-Sleep $IntervalSec
                }
                if (Test-Path $StopFile) { Write-Log 'Leállítási jelzés (fan_stop.flag) érkezett.' }
                else { Write-Log "Teszt vége ($cycle ciklus)." }
            } finally {
                try { Set-AllAuto; Write-Log 'Leállítás: gyári automatikus vezérlés visszaállítva (mindkét zóna).' }
                catch { Write-Log "FIGYELEM: az automatika visszaállítása sikertelen ($_) - futtasd: -Mode Restore" }
                Remove-Item $HeartbeatFile -Force -ErrorAction SilentlyContinue
            }
        }
    }
} catch {
    Write-Log "HIBA: $($_.Exception.Message)"
    if ($Mode -eq 'Run') { try { Set-AllAuto } catch {} }
    exit 1
} finally {
    if ($script:mutex) { try { $script:mutex.ReleaseMutex() } catch {}; $script:mutex.Dispose(); $script:mutex = $null }
}
Write-Log "Napló: $(Get-LogFile)"
