# Ollama on 2× Tesla V100 32 GB: 1 GPU vs 2 GPUs, context, KV cache, parallel serving

`ollama_benchmark.ps1` runs its own temporary `ollama serve` instances on ports **11534/11535**, so your normal server on 11434 keeps running untouched. For each configuration it measures:

- load time, model size, VRAM per GPU, and CPU offload (yes/no);
- a short generation (400 tokens);
- a long prompt filled to 70 % of the context: prompt processing speed (prefill tok/s) and generation speed after it;
- parallel serving with 4 concurrent requests in three layouts: 1 GPU, 2 GPUs spread, and 2 instances (one per GPU);
- a sustained load of 300 s with the best parallel layout.

While the tests run, `nvidia-smi` is sampled every 2 s. Fan RPM is taken from the [fan-control](../fan-control/) CSV log. Each phase gets max/avg temperature, power and utilization.

```powershell
.\ollama_benchmark.ps1                                                  # qwen3.5:4b + qwen3.8:27b
.\ollama_benchmark.ps1 -Models 'qwen3.5:35b-a3b' -SustainSec 0
.\ollama_benchmark.ps1 -Models 'llama3.3:70b' -Contexts 8192,32768,65536 -TwoGpuOnly -ParallelCtx 8192
```

The test servers start with `OLLAMA_NOPRUNE=1`. Ollama normally deletes unreferenced and `-partial` blobs at startup, which would destroy another machine's running download if the models directory is a shared network folder.

Setup: Ollama 0.40.17 (llama.cpp runner), all models Q4_K_M, driver 560.81 (TCC), PCIe Gen3 x16.

## qwen3.5:4b (4.2 B, hybrid attention)

| Config | Context | VRAM | Short gen | Long prompt prefill | Gen after long prompt |
|---|---|---|---|---|---|
| **1 GPU** | 32k | 3.9 GB | **68.0 tok/s** | 3 459 tok/s | 64.1 tok/s |
| 2 GPUs | 32k | 4.6 GB | 65.1 | 5 763 | 62.9 |
| 1 GPU | 131k | 7.5 GB | 65.6 | 1 786 | 52.0 |
| 2 GPUs | 131k | 11.6 GB | 65.7 | 3 261 | 52.0 |
| 1 GPU | 262k | 11.4 GB | 68.9 | 933 (186k tokens in 199 s) | 43.1 |
| 2 GPUs | 262k | 19.6 GB | 65.2 | **1 975** (94 s) | 41.9 |
| 1 GPU, FA + q8 KV | 262k | 8.6 GB | 66.9 | 919 | **28.3** |
| 2 GPUs, FA + q8 KV | 262k | 17.7 GB | 64.8 | 1 967 | 28.1 |

| Parallel, 4 concurrent requests | Total |
|---|---|
| 1 GPU, `NUM_PARALLEL=4` | 84.1 tok/s |
| 2 GPUs spread, `NUM_PARALLEL=4` | 82.2 tok/s |
| **2 instances (1 per GPU), `NUM_PARALLEL=2` each** | **141.6 tok/s** |

## qwen3.8:27b (27.3 B, hybrid attention)

| Config | Context | VRAM | Short gen | Long prompt prefill | Gen after long prompt |
|---|---|---|---|---|---|
| **1 GPU** | 32k | 16.4 GB | **41.1 tok/s** | 757 tok/s | 49.1 tok/s |
| 2 GPUs | 32k | 18.4 GB | 36.1 | 758 | 45.6 |
| **1 GPU** | 131k | 16.7 GB* | **45.3** | 370 (92k tokens in 249 s) | 35.9 |
| 2 GPUs | 131k | 23.3 GB | 43.7 | 441 (210 s) | 36.7 |
| 1 GPU | 262k | **does not fit, partly on CPU** | **6.3** ❌ | 174 | 2.1 |
| **2 GPUs** | 262k | 27.4 GB | **39.5** | 239 (186k tokens in 13 min) | **24.2** |
| 1 GPU, FA + q8 KV | 262k | 18.3 GB* | 40.3 | 232 | 21.1 |
| 2 GPUs, FA + q8 KV | 262k | 25.5 GB | 42.7 | 242 | 21.2 |

\* As reported by `ollama ps`. `nvidia-smi` showed 26.8 GB and 29.0 GB actually in use on the card.

| Parallel, 4 concurrent requests | Total |
|---|---|
| 1 GPU, `NUM_PARALLEL=4` | 64.9 tok/s |
| 2 GPUs spread, `NUM_PARALLEL=4` | 64.9 tok/s |
| **2 instances (1 per GPU), `NUM_PARALLEL=2` each** | **88.9 tok/s** |
| same, sustained 300 s (800-token answers) | 75 tok/s |

## Findings

1. **One request, model fits on one GPU: use one GPU.** Splitting layers over two cards is sequential, so generation is 3–12 % *slower*.
2. **The second GPU helps prompt processing** on long prompts: 2.1× for the 4B model, about 1.2× for the 27B.
3. **Several users: run one instance per GPU.** This gives 1.4–1.7× the total throughput of a single instance, whether that instance uses one GPU or both.
4. **Flash Attention + q8_0 KV cache on Volta saves memory but costs 12–35 % generation speed at long context.** Use it only to make something fit, e.g. 27B at 262k on a single card.
5. **Never pin a model to one GPU if it does not fit there.** With both GPUs visible, Ollama splits it automatically (39.5 tok/s instead of 6.3 tok/s).

### Recommended configuration

**A) One server, one user.** This also allows 70B models across both cards:

```
OLLAMA_FLASH_ATTENTION=0   OLLAMA_KV_CACHE_TYPE=f16   OLLAMA_NUM_PARALLEL=1
(OLLAMA_SCHED_SPREAD unset → model goes on one GPU if it fits, otherwise both)
num_ctx: 4B → up to 262144;  27B → 32768–131072 (262144 only if needed: gen drops to ~24 tok/s on long prompts)
```

**B) Several users or two models at once.** Use one instance per GPU:

```
instance 1:  CUDA_DEVICE_ORDER=PCI_BUS_ID  CUDA_VISIBLE_DEVICES=0  OLLAMA_HOST=0.0.0.0:11434  OLLAMA_NUM_PARALLEL=2
instance 2:  CUDA_DEVICE_ORDER=PCI_BUS_ID  CUDA_VISIBLE_DEVICES=1  OLLAMA_HOST=0.0.0.0:11435  OLLAMA_NUM_PARALLEL=2
```

## Thermals during the benchmark (2 h, fan-control active)

| | Max |
|---|---|
| GPU0 / GPU1 temperature | 72 °C / 66 °C |
| GPU power | 250–269 W peaks during prompt processing; 100–220 W while generating |
| Fan zone 1 / zone 2 | 88 % (13 400 RPM) / 70 % (10 500 RPM) |
| CPU VR / DIMM VR / PCH | 39 / 31 / 43 °C |

GPU0, on riser 1 (CPU1 side), consistently runs a few °C warmer than GPU1.

Raw data is in [`results/`](results/): `results.jsonl` (one line per test), `phases.csv` (thermals per phase), `gpu_samples.csv` (2 s samples) and `progress.txt` (run log, in Hungarian).

## Larger models (MoE 35B, 70B)

*Benchmark in progress: qwen3.5:35b-a3b, llama3.3:70b, deepseek-r1:70b. Results will be added here.*
