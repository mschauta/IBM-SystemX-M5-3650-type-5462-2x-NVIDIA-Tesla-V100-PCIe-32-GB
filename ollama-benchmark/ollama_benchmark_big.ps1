$ErrorActionPreference = 'Continue'
$b = Join-Path $PSScriptRoot 'ollama_benchmark.ps1'
# 1) MoE modell: elfér 1 GPU-n is, teljes menet
& $b -Models 'qwen3.5:35b-a3b' -Contexts 32768, 131072, 262144 -SustainSec 0
# 2) 70B modellek: csak 2 GPU, kisebb kontextus, tartós teszt a végén
& $b -Models 'llama3.3:70b', 'deepseek-r1:70b' -Contexts 8192, 32768, 65536 -TwoGpuOnly -ParallelCtx 8192 -SustainSec 300
