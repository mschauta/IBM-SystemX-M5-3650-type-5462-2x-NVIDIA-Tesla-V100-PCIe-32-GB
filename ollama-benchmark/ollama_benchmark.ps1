<#
.SYNOPSIS
  Ollama benchmark 2x Tesla V100-on: 1 GPU vs 2 GPU, kontextusméret, KV-cache, párhuzamosság,
  közben GPU-hőmérséklet/fogyasztás és ventilátor (a LenovoGpuFanControl CSV-jéből).
.EXAMPLE
  .\ollama_benchmark.ps1
  .\ollama_benchmark.ps1 -Models 'qwen3.5:4b' -SustainSec 120
#>
param(
    [string[]]$Models = @('qwen3.5:4b', 'qwen3.8:27b'),
    [int[]]$Contexts = @(32768, 131072, 262144),
    [int]$ShortPredict = 400,
    [int]$LongPredict = 200,
    [int]$ParallelRequests = 4,
    [int]$SustainSec = 300,
    [switch]$SkipLong,
    # Nagy (2 GPU-t igénylő) modellekhez: kihagyja az 1 GPU-s és a GPU-nkénti példányos eseteket
    [switch]$TwoGpuOnly,
    # A párhuzamos/tartós teszt kontextusa (70B-nél kisebb kell, mert a KV-cache a párhuzamossággal szorzódik)
    [int]$ParallelCtx = 32768,
    # Modellkönyvtár (alapértelmezés: a felhasználó OLLAMA_MODELS változója)
    [string]$ModelsDir = [Environment]::GetEnvironmentVariable('OLLAMA_MODELS', 'User')
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$OutDir = Join-Path $Root "logs\ollama_bench_$stamp"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$ProgressLog = Join-Path $OutDir 'progress.txt'
$ResultsFile = Join-Path $OutDir 'results.jsonl'
$SamplesFile = Join-Path $OutDir 'gpu_samples.csv'
$Phases = New-Object System.Collections.Generic.List[object]

function P([string]$m) { $l = "$(Get-Date -Format 'HH:mm:ss')  $m"; Write-Host $l; Add-Content $ProgressLog $l -Encoding UTF8 }

# ---------------------------------------------------------------------------
# GPU-mintavétel (háttérben, 2 s)
# ---------------------------------------------------------------------------
'ido,idx,temp,mem_temp,power,util,mem_used,sm_clock' | Set-Content $SamplesFile -Encoding ASCII
$sampler = Start-Job -ArgumentList $SamplesFile -ScriptBlock {
    param($f)
    while ($true) {
        $t = Get-Date -Format 's'
        $rows = & nvidia-smi --query-gpu=index,temperature.gpu,temperature.memory,power.draw,utilization.gpu,memory.used,clocks.sm --format=csv,noheader,nounits
        $rows | ForEach-Object { "$t,$($_ -replace '\s', '')" } | Add-Content $f -Encoding ASCII
        Start-Sleep 2
    }
}

# ---------------------------------------------------------------------------
# Ollama szerver kezelése
# ---------------------------------------------------------------------------
# Csak a saját (a benchmark által indított) szervereket és azok runner-folyamatait állítja le;
# a felhasználó saját Ollama szerverét (11534) nem érinti.
$script:srvProcs = @()
function Get-ProcTree([int]$Id) {
    $kids = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$Id" -ErrorAction SilentlyContinue)
    foreach ($k in $kids) { Get-ProcTree $k.ProcessId; $k.ProcessId }
}
function Stop-AllOllama {
    foreach ($p in $script:srvProcs) {
        $ids = @(Get-ProcTree $p.Id) + $p.Id
        foreach ($i in $ids) { Stop-Process -Id $i -Force -ErrorAction SilentlyContinue }
    }
    $script:srvProcs = @()
    Start-Sleep 4
}

function Start-Srv([string]$Gpus, [int]$Port, [hashtable]$Opt) {
    $env:CUDA_DEVICE_ORDER = 'PCI_BUS_ID'
    $env:CUDA_VISIBLE_DEVICES = $Gpus
    $env:OLLAMA_HOST = "127.0.0.1:$Port"
    $env:OLLAMA_KEEP_ALIVE = '60m'
    $env:OLLAMA_MAX_LOADED_MODELS = '1'
    # Közös (hálózati) modellkönyvtár: induláskor NE takarítson, mert más gépek félkész letöltéseit törölné
    $env:OLLAMA_NOPRUNE = '1'
    if ($ModelsDir) { $env:OLLAMA_MODELS = $ModelsDir }
    foreach ($k in 'OLLAMA_NUM_PARALLEL', 'OLLAMA_FLASH_ATTENTION', 'OLLAMA_KV_CACHE_TYPE', 'OLLAMA_SCHED_SPREAD') {
        if ($Opt.ContainsKey($k)) { Set-Item "env:$k" $Opt[$k] } else { Remove-Item "env:$k" -ErrorAction SilentlyContinue }
    }
    $log = Join-Path $OutDir ("ollama_{0}_{1}.log" -f $Port, (Get-Date -Format 'HHmmss'))
    $p = Start-Process ollama -ArgumentList 'serve' -WindowStyle Hidden -PassThru -RedirectStandardError $log -RedirectStandardOutput "$log.out"
    $script:srvProcs += $p
    for ($i = 0; $i -lt 60; $i++) {
        try { Invoke-RestMethod "http://127.0.0.1:$Port/api/version" -TimeoutSec 2 | Out-Null; return $p } catch { Start-Sleep 1 }
    }
    throw "Ollama szerver nem indult el (port $Port)"
}

function Invoke-Gen([int]$Port, [string]$Model, [string]$Prompt, [int]$Ctx, [int]$Predict) {
    $body = @{ model = $Model; prompt = $Prompt; stream = $false; keep_alive = '60m'
        options = @{ num_ctx = $Ctx; num_predict = $Predict; temperature = 0.7; seed = 42 } } | ConvertTo-Json -Depth 4
    $t0 = Get-Date
    try {
        $r = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/generate" -Method Post -TimeoutSec 7200 `
            -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8'
    } catch {
        $detail = ''
        try { $detail = (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() } catch {}
        throw "$($_.Exception.Message) $detail"
    }
    $r | Add-Member -NotePropertyName wall -NotePropertyValue ((Get-Date) - $t0).TotalSeconds -PassThru
}

function Get-GpuMem {
    $m = @{}
    & nvidia-smi --query-gpu=index,memory.used --format=csv,noheader,nounits | ForEach-Object {
        $v = $_ -split ',\s*'; $m[[int]$v[0]] = [int]$v[1] }
    $m
}

$rnd = New-Object System.Random 7
function New-ShortPrompt {
    "($($rnd.Next(100000))) Írj részletes, kb. 400 szavas magyar ismertetőt arról, hogyan működik egy szerver léghűtése, " +
    'és miért fontos a passzív hűtésű GPU-k esetében a megfelelő légáram. Használj alcímeket.'
}
function New-LongPrompt([int]$Tokens) {
    $lines = [int]($Tokens / 41)      # mérve: ~40,6 token/sor (qwen35 tokenizer)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("Server log export, batch $($rnd.Next(100000)). Read carefully, questions follow.")
    $st = 'ok', 'ok', 'ok', 'warn', 'ok', 'crit'
    for ($i = 0; $i -lt $lines; $i++) {
        [void]$sb.AppendLine(("Entry {0}: node-{1} rack {2} reported temperature {3} C, fan {4} rpm, power {5} W, status {6}." -f
            $i, ($i * 7919 % 997), ($i % 41), (35 + ($i * 13 % 45)), (3000 + ($i * 37 % 9000)), (80 + ($i * 11 % 170)), $st[$i % 6]))
    }
    [void]$sb.AppendLine('Question: summarize the log above in 5 sentences. Which nodes look critical and why?')
    $sb.ToString()
}

function Add-Result($o) { ($o | ConvertTo-Json -Compress -Depth 4) | Add-Content $ResultsFile -Encoding UTF8 }

function Start-Phase([string]$Name) { $script:phase = [pscustomobject]@{ Name = $Name; Start = Get-Date; End = $null }; $Phases.Add($script:phase) }
function End-Phase { $script:phase.End = Get-Date }

# ---------------------------------------------------------------------------
# 1) Egy kérés: 1 GPU vs 2 GPU, kontextusméret, FA + q8_0 KV
# ---------------------------------------------------------------------------
$singleCases = @()
foreach ($ctx in $Contexts) {
    $singleCases += @{ Gpu = '0'; Label = '1 GPU'; Ctx = $ctx; Opt = @{ OLLAMA_NUM_PARALLEL = '1' } }
    $singleCases += @{ Gpu = '0,1'; Label = '2 GPU'; Ctx = $ctx; Opt = @{ OLLAMA_NUM_PARALLEL = '1'; OLLAMA_SCHED_SPREAD = '1' } }
}
$maxCtx = ($Contexts | Measure-Object -Maximum).Maximum
$singleCases += @{ Gpu = '0'; Label = '1 GPU FA+q8'; Ctx = $maxCtx
    Opt = @{ OLLAMA_NUM_PARALLEL = '1'; OLLAMA_FLASH_ATTENTION = '1'; OLLAMA_KV_CACHE_TYPE = 'q8_0' } }
$singleCases += @{ Gpu = '0,1'; Label = '2 GPU FA+q8'; Ctx = $maxCtx
    Opt = @{ OLLAMA_NUM_PARALLEL = '1'; OLLAMA_SCHED_SPREAD = '1'; OLLAMA_FLASH_ATTENTION = '1'; OLLAMA_KV_CACHE_TYPE = 'q8_0' } }
if ($TwoGpuOnly) { $singleCases = @($singleCases | Where-Object { $_.Gpu -ne '0' }) }

try {
    P "Benchmark indul. Kimenet: $OutDir"
    Stop-AllOllama
    foreach ($model in $Models) {
        foreach ($c in $singleCases) {
            $name = "$model | $($c.Label) | ctx $($c.Ctx)"
            P "=== $name"
            $res = [ordered]@{ kind = 'single'; model = $model; config = $c.Label; ctx = $c.Ctx }
            try {
                Stop-AllOllama
                $null = Start-Srv $c.Gpu 11534 $c.Opt
                Start-Phase "$name | betöltés"
                $t0 = Get-Date
                $w = Invoke-Gen 11534 $model 'Szia!' $c.Ctx 4
                $res.load_s = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
                End-Phase
                $ps = (Invoke-RestMethod 'http://127.0.0.1:11534/api/ps').models | Select-Object -First 1
                $mem = Get-GpuMem
                $res.size_gb = [math]::Round($ps.size / 1GB, 1); $res.vram_gb = [math]::Round($ps.size_vram / 1GB, 1)
                $res.cpu_offload = ($ps.size_vram -lt $ps.size)
                $res.gpu0_mib = $mem[0]; $res.gpu1_mib = $mem[1]
                P ("   betöltés {0} s, méret {1} GB (VRAM {2} GB{3}), GPU0 {4} MiB, GPU1 {5} MiB" -f $res.load_s, $res.size_gb,
                    $res.vram_gb, $(if ($res.cpu_offload) { ', RÉSZBEN CPU-N!' } else { '' }), $mem[0], $mem[1])

                Start-Phase "$name | rövid"
                $r = Invoke-Gen 11534 $model (New-ShortPrompt) $c.Ctx $ShortPredict
                End-Phase
                $res.short_prompt_tok = $r.prompt_eval_count
                $res.short_gen_tps = [math]::Round($r.eval_count / ($r.eval_duration / 1e9), 1)
                P ("   rövid: {0} token, {1} token/s" -f $r.eval_count, $res.short_gen_tps)

                if (-not $SkipLong) {
                    $fill = [int]($c.Ctx * 0.70)
                    Start-Phase "$name | hosszú"
                    $r = Invoke-Gen 11534 $model (New-LongPrompt $fill) $c.Ctx $LongPredict
                    End-Phase
                    $res.long_prompt_tok = $r.prompt_eval_count
                    $res.long_prefill_tps = [math]::Round($r.prompt_eval_count / [math]::Max($r.prompt_eval_duration / 1e9, 1e-6), 0)
                    $res.long_prefill_s = [math]::Round($r.prompt_eval_duration / 1e9, 1)
                    $res.long_gen_tps = [math]::Round($r.eval_count / [math]::Max($r.eval_duration / 1e9, 1e-6), 1)
                    $mem = Get-GpuMem; $res.gpu0_mib_long = $mem[0]; $res.gpu1_mib_long = $mem[1]
                    P ("   hosszú: {0} token prompt ({1} token/s, {2} s), generálás {3} token/s" -f $res.long_prompt_tok,
                        $res.long_prefill_tps, $res.long_prefill_s, $res.long_gen_tps)
                }
            } catch {
                $res.error = $_.Exception.Message
                P "   HIBA: $($res.error)"
                if ($script:phase -and -not $script:phase.End) { End-Phase }
            }
            Add-Result $res
        }

        # -------------------------------------------------------------------
        # 2) Párhuzamos kiszolgálás: 4 egyidejű kérés
        # -------------------------------------------------------------------
        $parCases = @(
            @{ Label = '1 GPU, 4 párhuzamos'; Srv = @(@{ Gpu = '0'; Port = 11534 }); Opt = @{ OLLAMA_NUM_PARALLEL = "$ParallelRequests" } },
            @{ Label = '2 GPU elosztva, 4 párhuzamos'; Srv = @(@{ Gpu = '0,1'; Port = 11534 })
                Opt = @{ OLLAMA_NUM_PARALLEL = "$ParallelRequests"; OLLAMA_SCHED_SPREAD = '1' } },
            @{ Label = '2 példány (GPU-nként 1), 2+2 párhuzamos'; Srv = @(@{ Gpu = '0'; Port = 11534 }, @{ Gpu = '1'; Port = 11535 })
                Opt = @{ OLLAMA_NUM_PARALLEL = "$([math]::Ceiling($ParallelRequests / 2))" } }
        )
        if ($TwoGpuOnly) { $parCases = @($parCases | Where-Object { $_.Label -like '2 GPU elosztva*' }) }
        $best = $null
        foreach ($pc in $parCases) {
            $name = "$model | $($pc.Label)"
            P "=== $name"
            $res = [ordered]@{ kind = 'parallel'; model = $model; config = $pc.Label; ctx = $ParallelCtx }
            try {
                Stop-AllOllama
                foreach ($s in $pc.Srv) { $null = Start-Srv $s.Gpu $s.Port $pc.Opt }
                foreach ($s in $pc.Srv) { $null = Invoke-Gen $s.Port $model 'Szia!' $ParallelCtx 4 }
                Start-Phase $name
                $jobs = for ($i = 0; $i -lt $ParallelRequests; $i++) {
                    $port = $pc.Srv[$i % $pc.Srv.Count].Port
                    Start-Job -ArgumentList $port, $model, (New-ShortPrompt), $ShortPredict -ScriptBlock {
                        param($port, $model, $prompt, $n)
                        $body = @{ model = $model; prompt = $prompt; stream = $false; keep_alive = '60m'
                            options = @{ num_ctx = $using:ParallelCtx; num_predict = $n; temperature = 0.7 } } | ConvertTo-Json -Depth 4
                        $t0 = Get-Date
                        $r = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/generate" -Method Post -TimeoutSec 3600 `
                            -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8'
                        [pscustomobject]@{ Start = $t0; End = Get-Date; Tokens = $r.eval_count; Tps = $r.eval_count / ($r.eval_duration / 1e9) }
                    }
                }
                $out = $jobs | Wait-Job | Receive-Job; $jobs | Remove-Job
                End-Phase
                $span = (($out | Measure-Object End -Maximum).Maximum - ($out | Measure-Object Start -Minimum).Minimum).TotalSeconds
                $res.total_tokens = ($out | Measure-Object Tokens -Sum).Sum
                $res.aggregate_tps = [math]::Round($res.total_tokens / $span, 1)
                $res.per_request_tps = [math]::Round(($out | Measure-Object Tps -Average).Average, 1)
                $mem = Get-GpuMem; $res.gpu0_mib = $mem[0]; $res.gpu1_mib = $mem[1]
                P ("   összesen {0} token/s ({1} kérés, kérésenként átl. {2} token/s)" -f $res.aggregate_tps, $out.Count, $res.per_request_tps)
                if (-not $best -or $res.aggregate_tps -gt $best.Tps) { $best = @{ Case = $pc; Tps = $res.aggregate_tps } }
            } catch {
                $res.error = $_.Exception.Message; P "   HIBA: $($res.error)"
                if ($script:phase -and -not $script:phase.End) { End-Phase }
            }
            Add-Result $res
        }

        # -------------------------------------------------------------------
        # 3) Tartós terhelés a legjobb párhuzamos beállítással (csak a nagy modellnél)
        # -------------------------------------------------------------------
        if ($best -and $SustainSec -gt 0 -and $model -eq $Models[-1]) {
            $pc = $best.Case
            $name = "$model | TARTÓS $SustainSec s | $($pc.Label)"
            P "=== $name"
            $res = [ordered]@{ kind = 'sustain'; model = $model; config = $pc.Label; seconds = $SustainSec }
            try {
                Stop-AllOllama
                foreach ($s in $pc.Srv) { $null = Start-Srv $s.Gpu $s.Port $pc.Opt }
                foreach ($s in $pc.Srv) { $null = Invoke-Gen $s.Port $model 'Szia!' $ParallelCtx 4 }
                Start-Phase $name
                $tEnd = (Get-Date).AddSeconds($SustainSec); $tok = 0; $t0 = Get-Date
                while ((Get-Date) -lt $tEnd) {
                    $jobs = for ($i = 0; $i -lt $ParallelRequests; $i++) {
                        $port = $pc.Srv[$i % $pc.Srv.Count].Port
                        Start-Job -ArgumentList $port, $model, (New-ShortPrompt) -ScriptBlock {
                            param($port, $model, $prompt)
                            $body = @{ model = $model; prompt = $prompt; stream = $false; keep_alive = '60m'
                                options = @{ num_ctx = $using:ParallelCtx; num_predict = 800; temperature = 0.7 } } | ConvertTo-Json -Depth 4
                            (Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/generate" -Method Post -TimeoutSec 3600 `
                                -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8').eval_count
                        }
                    }
                    $tok += ($jobs | Wait-Job | Receive-Job | Measure-Object -Sum).Sum; $jobs | Remove-Job
                }
                End-Phase
                $res.total_tokens = $tok; $res.aggregate_tps = [math]::Round($tok / ((Get-Date) - $t0).TotalSeconds, 1)
                P ("   tartós: {0} token/s összesen" -f $res.aggregate_tps)
            } catch {
                $res.error = $_.Exception.Message; P "   HIBA: $($res.error)"
                if ($script:phase -and -not $script:phase.End) { End-Phase }
            }
            Add-Result $res
        }
    }
} finally {
    Stop-AllOllama
    foreach ($k in 'CUDA_VISIBLE_DEVICES', 'CUDA_DEVICE_ORDER', 'OLLAMA_HOST', 'OLLAMA_KEEP_ALIVE', 'OLLAMA_MAX_LOADED_MODELS',
        'OLLAMA_NUM_PARALLEL', 'OLLAMA_FLASH_ATTENTION', 'OLLAMA_KV_CACHE_TYPE', 'OLLAMA_SCHED_SPREAD') { Remove-Item "env:$k" -ErrorAction SilentlyContinue }
    Stop-Job $sampler -ErrorAction SilentlyContinue; Remove-Job $sampler -Force -ErrorAction SilentlyContinue

    # -----------------------------------------------------------------------
    # Fázisonkénti hő- és ventilátorstatisztika
    # -----------------------------------------------------------------------
    $samples = Import-Csv $SamplesFile | ForEach-Object {
        [pscustomobject]@{ T = [datetime]$_.ido; Idx = [int]$_.idx; Temp = [int]$_.temp; Power = [double]$_.power; Util = [int]$_.util } }
    $fanCsv = Join-Path $Root ("logs\fan_run_{0}.csv" -f (Get-Date -Format 'yyyyMMdd'))
    $fans = @()
    if (Test-Path $fanCsv) {
        $fans = Import-Csv $fanCsv | ForEach-Object { [pscustomobject]@{ T = [datetime]$_.ido
            Z1 = $(if ($_.z1_rpm) { [int]$_.z1_rpm } else { $null }); Z2 = $(if ($_.z2_rpm) { [int]$_.z2_rpm } else { $null })
            Z1p = $_.z1_pct; Z2p = $_.z2_pct } }
    }
    $phaseRows = foreach ($ph in $Phases) {
        if (-not $ph.End) { continue }
        $w = @($samples | Where-Object { $_.T -ge $ph.Start -and $_.T -le $ph.End })
        $f = @($fans | Where-Object { $_.T -ge $ph.Start -and $_.T -le $ph.End })
        $o = [ordered]@{ phase = $ph.Name; seconds = [math]::Round(($ph.End - $ph.Start).TotalSeconds, 0) }
        foreach ($g in 0, 1) {
            $s = @($w | Where-Object Idx -eq $g)
            $o["gpu${g}_tmax"] = ($s | Measure-Object Temp -Maximum).Maximum
            $o["gpu${g}_pavg"] = [math]::Round(($s | Measure-Object Power -Average).Average, 0)
            $o["gpu${g}_pmax"] = [math]::Round(($s | Measure-Object Power -Maximum).Maximum, 0)
            $o["gpu${g}_util"] = [math]::Round(($s | Measure-Object Util -Average).Average, 0)
        }
        $o.z1_rpm_max = ($f | Where-Object Z1 | Measure-Object Z1 -Maximum).Maximum
        $o.z2_rpm_max = ($f | Where-Object Z2 | Measure-Object Z2 -Maximum).Maximum
        [pscustomobject]$o
    }
    $phaseRows | Export-Csv (Join-Path $OutDir 'phases.csv') -NoTypeInformation -Encoding UTF8
    P "Kész. Eredmények: $ResultsFile, fázisok: $(Join-Path $OutDir 'phases.csv')"
}
