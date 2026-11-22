<#
.SYNOPSIS
  Rendszerfogyasztás kiolvasása az IMM2-ből (csak olvas): DCMI Power Reading + az SDR összes
  watt-mértékegységű érzékelője, mellette a GPU-k fogyasztása az nvidia-smi-ből.
.EXAMPLE
  .\Read-ServerPower.ps1                    # egyszeri kiolvasás
  .\Read-ServerPower.ps1 -Seconds 600       # 10 percig, 5 s-onként mintavétel + összegzés
#>
param(
    [int]$Seconds = 0,
    [int]$IntervalSec = 5,
    [string]$LogDir = ''
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $LogDir) { $LogDir = Join-Path $Root 'logs' }
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$csv = Join-Path $LogDir "power_$stamp.csv"
$txt = Join-Path $LogDir "power_$stamp.txt"
function Out-Line([string]$m) { Write-Host $m; Add-Content -Path $txt -Value $m -Encoding UTF8 }

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Rendszergazdai PowerShell szükséges.' }
$ipmi = Get-CimInstance -Namespace root/wmi -ClassName Microsoft_IPMI | Select-Object -First 1
if (-not $ipmi) { throw 'Microsoft_IPMI nem érhető el.' }

function Invoke-Ipmi([byte]$NetFn, [byte]$Cmd, [byte[]]$Data = @()) {
    # Csak olvasó parancsok: Get Device ID, SDR info/reserve/get, Get Sensor Reading, DCMI Get Power Reading
    $allowed = @('6:1', '10:32', '10:34', '10:35', '4:45', '44:2')
    if ($allowed -notcontains "$NetFn`:$Cmd") { throw "Nem engedélyezett IPMI parancs: NetFn $NetFn Cmd $Cmd" }
    $req = if ($Data.Count -gt 0) { $Data } else { [byte[]]@(0) }
    $r = Invoke-CimMethod -InputObject $ipmi -MethodName RequestResponse -Arguments @{
        Command = $Cmd; Lun = [byte]0; NetworkFunction = $NetFn; ResponderAddress = [byte]0x20
        RequestData = [byte[]]$req; RequestDataSize = [uint32]$Data.Count
    }
    $resp = [byte[]]$r.ResponseData
    if ($null -eq $resp -or $resp.Count -lt 1) { throw "Üres IPMI válasz (NetFn $NetFn Cmd $Cmd)" }
    if ($resp[0] -ne 0) { throw ("IPMI completion code 0x{0:X2}" -f $resp[0]) }
    return $resp
}
function Convert-Signed([int]$v, [int]$bits) { if ($v -band (1 -shl ($bits - 1))) { $v - (1 -shl $bits) } else { $v } }

function Get-SensorList {
    $resv = Invoke-Ipmi 10 34; $r0, $r1 = $resv[1], $resv[2]
    $list = @(); $recId = 0; $seen = @{}
    while ($recId -ne 0xFFFF -and -not $seen.ContainsKey($recId) -and $seen.Count -lt 1000) {
        $seen[$recId] = $true
        $h = Invoke-Ipmi 10 35 ([byte[]]@($r0, $r1, ($recId -band 0xFF), ($recId -shr 8), 0, 5))
        $next = $h[1] + ($h[2] -shl 8); $hdr = $h[3..7]; $len = $hdr[4]
        $body = New-Object System.Collections.Generic.List[byte]; $off = 5
        while ($body.Count -lt $len) {
            $n = [math]::Min(16, $len - $body.Count)
            $c = Invoke-Ipmi 10 35 ([byte[]]@($r0, $r1, ($recId -band 0xFF), ($recId -shr 8), $off, $n))
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
    $list | Sort-Object Num -Unique
}
function Read-Sensor($s) {
    try { $r = Invoke-Ipmi 4 45 ([byte[]]@($s.Num)) } catch { return $null }
    if ($r.Count -ge 3 -and ($r[2] -band 0x20)) { return $null }
    $x = [int]$r[1]
    if ($s.Fmt -eq 1) { $x = Convert-Signed $x 8; if ($x -lt 0) { $x += 1 } } elseif ($s.Fmt -eq 2) { $x = Convert-Signed $x 8 }
    [math]::Round(($s.M * $x + $s.B * [math]::Pow(10, $s.BExp)) * [math]::Pow(10, $s.RExp), 1)
}
function Read-Dcmi {
    try {
        $r = Invoke-Ipmi 44 2 ([byte[]]@(0xDC, 0x01, 0x00, 0x00))
        [pscustomobject]@{ Cur = $r[2] + 256 * $r[3]; Min = $r[4] + 256 * $r[5]; Max = $r[6] + 256 * $r[7]; Avg = $r[8] + 256 * $r[9]
            PeriodS = [math]::Round(([uint32]$r[14] + 256 * [uint32]$r[15] + 65536 * [uint32]$r[16] + 16777216 * [uint32]$r[17]) / 1000); Active = [bool]($r[18] -band 0x40) }
    } catch { $null }
}
function Read-GpuPower {
    $rows = & nvidia-smi --query-gpu=index,power.draw,temperature.gpu,utilization.gpu --format=csv,noheader,nounits
    $rows | ForEach-Object { $v = $_ -split ',\s*'; [pscustomobject]@{ Idx = [int]$v[0]; W = [double]$v[1]; T = [int]$v[2]; U = [int]$v[3] } }
}

Out-Line "Szerver fogyasztás (IMM2) - $(Get-Date)"
Out-Line 'Érzékelőlista beolvasása...'
$all = @(Get-SensorList)
# IPMI mértékegység 6 = Watt; tápegység (0x08) és áram (0x03) típusú, számszerű érzékelők is
$pw = @($all | Where-Object { $_.Unit -eq 6 -or (($_.Type -eq 0x08 -or $_.Name -match 'PS|Power|Pwr|Watt') -and $_.Unit -in 4, 5, 6) })
Out-Line ("  {0} érzékelő, ebből teljesítmény/táp: {1}" -f $all.Count, (($pw | ForEach-Object { $_.Name }) -join ', '))
$d = Read-Dcmi
if ($d) { Out-Line ("  DCMI: most {0} W, min {1} W, max {2} W, átlag {3} W ({4} s statisztikai ablak)" -f $d.Cur, $d.Min, $d.Max, $d.Avg, $d.PeriodS) }
else { Out-Line '  DCMI Power Reading: nem támogatott' }

$cols = @('ido', 'dcmi_w') + @($pw | ForEach-Object { $_.Name -replace '[ ,]', '_' }) + @('gpu0_w', 'gpu1_w', 'gpu0_t', 'gpu1_t', 'gpu0_util', 'gpu1_util')
($cols -join ',') | Set-Content $csv -Encoding ASCII
$samples = New-Object System.Collections.Generic.List[object]
$tEnd = (Get-Date).AddSeconds($Seconds)
do {
    $d = Read-Dcmi; $g = @(Read-GpuPower)
    $vals = [ordered]@{ ido = (Get-Date -Format 's'); dcmi_w = $(if ($d) { $d.Cur } else { '' }) }
    foreach ($s in $pw) { $vals[$s.Name] = Read-Sensor $s }
    $vals.gpu0_w = $g[0].W; $vals.gpu1_w = $g[1].W; $vals.gpu0_t = $g[0].T; $vals.gpu1_t = $g[1].T; $vals.gpu0_util = $g[0].U; $vals.gpu1_util = $g[1].U
    ($vals.Values -join ',') | Add-Content $csv -Encoding ASCII
    $samples.Add([pscustomobject]$vals)
    Out-Line ("{0}  rendszer {1} W | {2} | GPU0 {3:N0} W {4}% | GPU1 {5:N0} W {6}%" -f $vals.ido, $vals.dcmi_w,
        (($pw | ForEach-Object { "$($_.Name) $($vals[$_.Name])" }) -join ' | '), $g[0].W, $g[0].U, $g[1].W, $g[1].U)
    if ($Seconds -gt 0 -and (Get-Date) -lt $tEnd) { Start-Sleep $IntervalSec }
} while ($Seconds -gt 0 -and (Get-Date) -lt $tEnd)

if ($samples.Count -gt 1) {
    Out-Line '--- Összegzés'
    foreach ($k in @('dcmi_w') + @($pw | ForEach-Object { $_.Name }) + @('gpu0_w', 'gpu1_w')) {
        $v = @($samples | ForEach-Object { $_.$k } | Where-Object { "$_" -match '^\d' } | ForEach-Object { [double]$_ })
        if ($v.Count) { Out-Line ("  {0,-20} min {1,6:N0}  átlag {2,6:N0}  max {3,6:N0} W" -f $k, ($v | Measure-Object -Minimum).Minimum,
            ($v | Measure-Object -Average).Average, ($v | Measure-Object -Maximum).Maximum) }
    }
}
Out-Line "Napló: $txt"
Out-Line "CSV:   $csv"
