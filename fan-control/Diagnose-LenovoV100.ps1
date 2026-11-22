<#
.SYNOPSIS
  Lenovo/IBM System x3650 M5 + 2x Tesla V100 - CSAK OLVASÓ diagnosztika (1. fázis).

.DESCRIPTION
  - GPU-k: azonosítás, hőmérséklet, fogyasztás, korlát, throttle okok (nvidia-smi)
  - Szerver: modell, BIOS-verzió (sorozatszámot NEM naplóz)
  - IMM2: in-band IPMI a Windows IPMI driverén át (WMI Microsoft_IPMI), ipmitool nélkül:
      Get Device ID (firmware), SDR-bejárás, ventilátor-RPM, hőmérséklet- és teljesítményszenzorok
  - IMM LAN-over-USB elérhetőség (169.254.95.118)

  Csak szabványos OLVASÓ IPMI-parancsokat küld:
      App 0x06/0x01 Get Device ID
      Storage 0x0A/0x20 Get SDR Repository Info, 0x22 Reserve SDR, 0x23 Get SDR
      Sensor 0x04/0x2D Get Sensor Reading
  OEM (0x3A) vagy bármilyen író/ventilátorvezérlő parancsot NEM küld.

  Az IPMI-részhez rendszergazdai PowerShell kell; anélkül a GPU/BIOS-rész akkor is lefut.

.EXAMPLE
  .\Diagnose-LenovoV100.ps1
#>
[CmdletBinding()]
param(
    [string]$LogDir = ''
)

$ErrorActionPreference = 'Continue'
if (-not $LogDir) {
    $root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $LogDir = Join-Path $root 'logs'
}
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
$logFile = Join-Path $LogDir "diagnostics_$stamp.txt"

function Write-Log([string]$msg = '') {
    Write-Host $msg
    Add-Content -Path $logFile -Value $msg -Encoding UTF8
}
function Write-Section([string]$t) {
    Write-Log ''
    Write-Log ('=' * 70)
    Write-Log " $t"
    Write-Log ('=' * 70)
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

Write-Log "Lenovo V100 diagnosztika (1. fázis, csak olvasás) - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Log "Rendszergazda: $(if ($isAdmin) { 'igen' } else { 'NEM (az IPMI-rész kimarad)' })"

# ---------------------------------------------------------------------------
Write-Section '1. Szerver és BIOS'
$cs   = Get-CimInstance Win32_ComputerSystem
$bios = Get-CimInstance Win32_BIOS
$os   = Get-CimInstance Win32_OperatingSystem
Write-Log "  Gyártó / modell : $($cs.Manufacturer) / $($cs.Model)"
Write-Log "  BIOS (UEFI)     : $($bios.SMBIOSBIOSVersion)  ($($bios.ReleaseDate.ToString('yyyy-MM-dd')))"
Write-Log "  Operációs rend. : $($os.Caption) build $($os.BuildNumber)"
Write-Log "  CPU             : $((Get-CimInstance Win32_Processor | ForEach-Object { $_.Name.Trim() }) -join ' | ')"
Write-Log "  RAM             : $([math]::Round($cs.TotalPhysicalMemory / 1GB, 1)) GB"

# ---------------------------------------------------------------------------
Write-Section '2. GPU-k (nvidia-smi)'
$smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
if (-not $smi) {
    Write-Log '  nvidia-smi nem található.'
} else {
    $fields = 'index,name,pci.bus_id,driver_version,driver_model.current,temperature.gpu,temperature.memory,' +
              'power.draw,power.limit,power.max_limit,pstate,clocks.sm,clocks.max.sm,' +
              'clocks_throttle_reasons.active,pcie.link.gen.current,pcie.link.width.current,' +
              'memory.used,memory.total,ecc.mode.current,utilization.gpu'
    $rows = & nvidia-smi "--query-gpu=$fields" --format=csv,noheader,nounits 2>&1
    $names = $fields.Split(',')
    foreach ($r in $rows) {
        $v = ($r -split ',\s*')
        if ($v.Count -lt $names.Count) { Write-Log "  $r"; continue }
        $g = @{}; for ($i = 0; $i -lt $names.Count; $i++) { $g[$names[$i]] = $v[$i].Trim() }
        Write-Log ''
        Write-Log "  GPU $($g['index']): $($g['name'])  busz $($g['pci.bus_id'])  driver $($g['driver_version']) ($($g['driver_model.current']))"
        Write-Log "    Hőmérséklet   : GPU $($g['temperature.gpu']) °C, HBM2 $($g['temperature.memory']) °C"
        Write-Log "    Fogyasztás    : $($g['power.draw']) W  (korlát $($g['power.limit']) W, max $($g['power.max_limit']) W)"
        Write-Log "    Állapot       : $($g['pstate']), SM $($g['clocks.sm'])/$($g['clocks.max.sm']) MHz, kihasználtság $($g['utilization.gpu']) %"
        Write-Log "    Throttle okok : $($g['clocks_throttle_reasons.active'])"
        Write-Log "    PCIe          : Gen$($g['pcie.link.gen.current']) x$($g['pcie.link.width.current'])"
        Write-Log "    VRAM          : $($g['memory.used']) / $($g['memory.total']) MiB, ECC: $($g['ecc.mode.current'])"
    }
}

# ---------------------------------------------------------------------------
Write-Section '3. IMM2 elérhetőség'
Get-PnpDevice -ErrorAction SilentlyContinue |
    Where-Object { $_.FriendlyName -match 'IPMI|IMM|Remote NDIS' } |
    ForEach-Object { Write-Log "  Eszköz: [$($_.Status)] $($_.FriendlyName)" }
$usbIp = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -like '169.254.95.*' }
if ($usbIp) {
    Write-Log "  LAN-over-USB    : gép oldali cím $($usbIp.IPAddress) ($($usbIp.InterfaceAlias))"
    $ping = Test-Connection -ComputerName 169.254.95.118 -Count 2 -Quiet -ErrorAction SilentlyContinue
    Write-Log "  IMM 169.254.95.118 ping: $(if ($ping) { 'válaszol' } else { 'nem válaszol' })"
} else {
    Write-Log '  LAN-over-USB    : nincs 169.254.95.x cím'
}

# ---------------------------------------------------------------------------
Write-Section '4. IMM2 in-band IPMI (firmware, ventilátorok, szenzorok)'

$script:ipmi = $null
function Invoke-Ipmi([byte]$NetFn, [byte]$Cmd, [byte[]]$Data = @()) {
    # Csak olvasó parancsok engedélyezettek ebben a scriptben
    $allowed = @('6:1', '10:32', '10:34', '10:35', '4:45')
    if ($allowed -notcontains "$NetFn`:$Cmd") { throw "Nem engedélyezett IPMI parancs: NetFn $NetFn Cmd $Cmd" }
    $req = if ($Data.Count -gt 0) { $Data } else { [byte[]]@(0) }
    $r = Invoke-CimMethod -InputObject $script:ipmi -MethodName RequestResponse -Arguments @{
        Command = $Cmd; Lun = [byte]0; NetworkFunction = $NetFn; ResponderAddress = [byte]0x20
        RequestData = [byte[]]$req; RequestDataSize = [uint32]$Data.Count
    } -ErrorAction Stop
    $resp = [byte[]]$r.ResponseData
    if ($null -eq $resp -or $resp.Count -lt 1) { throw "Üres IPMI válasz (NetFn $NetFn Cmd $Cmd)" }
    if ($resp[0] -ne 0) { throw ("IPMI completion code 0x{0:X2} (NetFn {1} Cmd {2})" -f $resp[0], $NetFn, $Cmd) }
    return $resp
}

function Convert-Signed([int]$v, [int]$bits) { if ($v -band (1 -shl ($bits - 1))) { $v - (1 -shl $bits) } else { $v } }

$unitNames = @{ 1 = '°C'; 4 = 'V'; 5 = 'A'; 6 = 'W'; 18 = 'RPM'; 19 = 'Hz'; 0 = '' }
$typeNames = @{ 1 = 'hőmérséklet'; 2 = 'feszültség'; 3 = 'áram / teljesítmény'; 4 = 'ventilátor'; 8 = 'tápegység'; 11 = 'kihasználtság (%)' }

if (-not $isAdmin) {
    Write-Log '  KIHAGYVA: rendszergazdai PowerShell szükséges (Microsoft_IPMI hozzáférés).'
} else {
    try {
        $script:ipmi = Get-CimInstance -Namespace root/wmi -ClassName Microsoft_IPMI -ErrorAction Stop | Select-Object -First 1
        if (-not $script:ipmi) { throw 'Microsoft_IPMI példány nem található' }

        # --- Get Device ID ---
        $d = Invoke-Ipmi 6 1
        $fwMajor = $d[3] -band 0x7F
        $fwMinor = '{0:X2}' -f $d[4]
        $ipmiVer = '{0}.{1}' -f ($d[5] -band 0x0F), ($d[5] -shr 4)
        $mfg = $d[7] + ($d[8] -shl 8) + ($d[9] -shl 16)
        $aux = if ($d.Count -ge 16) { ($d[12..15] | ForEach-Object { '{0:X2}' -f $_ }) -join ' ' } else { 'n/a' }
        Write-Log "  IMM firmware rev.: $fwMajor.$fwMinor  (IPMI $ipmiVer, gyártó ID $mfg, aux $aux)"
        Write-Log '  (A teljes IMM2 build-azonosító, pl. TCOO..., az IMM webes felületén / OneCLI-ben látható.)'

        # --- SDR bejárás ---
        $info = Invoke-Ipmi 10 32
        Write-Log "  SDR rekordok     : $($info[2] + ($info[3] -shl 8))"
        $resv = Invoke-Ipmi 10 34
        $rid0, $rid1 = $resv[1], $resv[2]

        function Get-SdrBytes([int]$recId, [int]$offset, [int]$count) {
            $req = [byte[]]@($rid0, $rid1, ($recId -band 0xFF), ($recId -shr 8), $offset, $count)
            return Invoke-Ipmi 10 35 $req
        }

        $sensors = @()
        $recId = 0; $guard = 0
        $seenRec = @{}
        while ($recId -ne 0xFFFF -and $guard -lt 1000 -and -not $seenRec.ContainsKey($recId)) {
            $guard++
            $seenRec[$recId] = $true
            $h = Get-SdrBytes $recId 0 5
            $next = $h[1] + ($h[2] -shl 8)
            $hdr = $h[3..7]
            $recType = $hdr[3]; $len = $hdr[4]
            $body = New-Object System.Collections.Generic.List[byte]
            $off = 5
            while ($body.Count -lt $len) {
                $n = [math]::Min(16, $len - $body.Count)
                $c = Get-SdrBytes $recId $off $n
                $body.AddRange([byte[]]$c[3..($c.Count - 1)])
                $off += $n
            }
            $rec = [byte[]]($hdr + $body.ToArray())
            if ($recType -eq 1 -and $rec.Count -ge 48) {
                $idLen = $rec[47] -band 0x1F
                $sensors += [pscustomobject]@{
                    Num = $rec[7]; Owner = $rec[5]; Type = $rec[12]; Fmt = ($rec[20] -shr 6); Unit = $rec[21]
                    M = Convert-Signed ($rec[24] + (($rec[25] -band 0xC0) -shl 2)) 10
                    B = Convert-Signed ($rec[26] + (($rec[27] -band 0xC0) -shl 2)) 10
                    RExp = Convert-Signed ($rec[29] -shr 4) 4; BExp = Convert-Signed ($rec[29] -band 0x0F) 4
                    Name = [Text.Encoding]::ASCII.GetString($rec, 48, [math]::Min($idLen, $rec.Count - 48)).Trim([char]0, ' ')
                }
            }
            $recId = $next
        }

        # --- Szenzorleolvasás ---
        $wanted = $sensors | Where-Object { $_.Owner -eq 0x20 -and $_.Type -in 1, 4, 8, 11 -or $_.Unit -in 6, 18 } |
            Sort-Object Num -Unique
        foreach ($grp in ($wanted | Group-Object Type | Sort-Object { if ($_.Name -eq '4') { 0 } else { 1 } }, Name)) {
            $tn = $typeNames[[int]$grp.Name]; if (-not $tn) { $tn = "típus $($grp.Name)" }
            Write-Log ''
            Write-Log "  --- $tn ---"
            foreach ($s in $grp.Group) {
                try {
                    $r = Invoke-Ipmi 4 45 ([byte[]]@($s.Num))
                    if ($r.Count -ge 3 -and ($r[2] -band 0x20)) { $val = 'nem elérhető' }
                    else {
                        $x = [int]$r[1]
                        if ($s.Fmt -eq 1) { $x = Convert-Signed $x 8; if ($x -lt 0) { $x += 1 } }
                        elseif ($s.Fmt -eq 2) { $x = Convert-Signed $x 8 }
                        $y = ($s.M * $x + $s.B * [math]::Pow(10, $s.BExp)) * [math]::Pow(10, $s.RExp)
                        $u = $unitNames[[int]$s.Unit]; if ($null -eq $u) { $u = "(egység $($s.Unit))" }
                        $val = '{0:0.##} {1}' -f $y, $u
                    }
                } catch {
                    $val = if ($_.Exception.Message -match '0xCB') { 'nincs jelen (nincs beszerelve / nem olvasható)' }
                           else { "hiba: $($_.Exception.Message)" }
                }
                Write-Log ('    {0,-24} {1}' -f $s.Name, $val)
            }
        }
        if (-not $wanted) { Write-Log '  Nem található analóg ventilátor/hőmérséklet szenzor az SDR-ben.' }
    } catch {
        Write-Log "  IPMI HIBA: $($_.Exception.Message)"
    }
}

Write-Log ''
Write-Log "Napló: $logFile"
Write-Log 'A script semmilyen ventilátor-, firmware- vagy BIOS-beállítást nem módosított.'
