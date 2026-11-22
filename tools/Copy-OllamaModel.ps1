<#
.SYNOPSIS
  Ollama modell(ek) másolása egyik modellkönyvtárból a másikba (manifest + hivatkozott blobok).
  A forrást csak olvassa. Már meglévő, azonos méretű blobot nem másol újra.
.EXAMPLE
  .\Copy-OllamaModel.ps1 -Source '\\server\share\Ollama\models' -Dest 'D:\ollama_models' -Models 'llama3.3:70b','deepseek-r1:70b'
#>
param(
    [Parameter(Mandatory)] [string]$Source,
    [Parameter(Mandatory)] [string]$Dest,
    [Parameter(Mandatory)] [string[]]$Models
)
$ErrorActionPreference = 'Stop'
foreach ($m in $Models) {
    $name, $tag = $m -split ':', 2; if (-not $tag) { $tag = 'latest' }
    $ns = if ($name -match '/') { $name } else { "library/$name" }
    $rel = "manifests\registry.ollama.ai\$($ns -replace '/', '\')\$tag"
    $src = Join-Path $Source $rel
    if (-not (Test-Path $src)) { throw "Nincs manifest: $src" }
    $man = Get-Content $src -Raw | ConvertFrom-Json
    $digests = @($man.config.digest) + @($man.layers | ForEach-Object { $_.digest })
    New-Item -ItemType Directory -Force (Join-Path $Dest 'blobs') | Out-Null
    foreach ($dg in $digests) {
        $f = $dg -replace ':', '-'
        $s = Join-Path $Source "blobs\$f"; $d = Join-Path $Dest "blobs\$f"
        $len = (Get-Item $s).Length
        if ((Test-Path $d) -and (Get-Item $d).Length -eq $len) { "  megvan: $f"; continue }
        $t0 = Get-Date
        Copy-Item $s $d -Force
        $sec = [math]::Max(((Get-Date) - $t0).TotalSeconds, 0.1)
        "  {0}  {1:N2} GB  {2:N0} s  {3:N0} MB/s" -f $f.Substring(0, 19), ($len / 1GB), $sec, ($len / 1MB / $sec)
    }
    $dm = Join-Path $Dest $rel
    New-Item -ItemType Directory -Force (Split-Path $dm) | Out-Null
    Copy-Item $src $dm -Force
    "$m kész"
}
