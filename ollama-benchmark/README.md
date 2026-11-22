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

## qwen3.5:35b-a3b (MoE, 35 B total / about 3 B active per token)

| Config | Context | VRAM | Short gen | Long prompt prefill | Gen after long prompt |
|---|---|---|---|---|---|
| **1 GPU** | 32k | 20.6 GB | **62.9 tok/s** | 478 tok/s | 59.7 tok/s |
| 2 GPUs | 32k | 21.4 GB | 60.3 | 481 | 57.9 |
| 1 GPU | 131k | 22.5 GB | 63.3 | 354 (92k tokens in 261 s) | 52.9 |
| 2 GPUs | 131k | 27.3 GB | 60.3 | 469 (197 s) | 51.5 |
| **1 GPU** | 262k | 25.1 GB | 63.2 | 287 (186k tokens in 11 min) | **45.1** |
| 2 GPUs | 262k | 33.8 GB | 60.2 | 376 (8 min) | 44.4 |
| 1 GPU, FA + q8 KV | 262k | 23.2 GB | 62.3 | 288 | 33.5 |
| 2 GPUs, FA + q8 KV | 262k | 32.1 GB | 59.2 | 372 | 33.1 |

| Parallel, 4 concurrent requests | Total |
|---|---|
| 1 GPU, `NUM_PARALLEL=4` | 71.2 tok/s |
| 2 GPUs spread | 63.2 tok/s |
| **2 instances (1 per GPU)** | **112.7 tok/s** |

Compared with the dense 27B, the MoE model:

- **generates faster:** 63 vs 41–45 tok/s; after a 186k prompt, 45 vs 24 tok/s;
- **processes prompts slower:** 478 vs 757 tok/s at 32k;
- **runs cooler:** about 155 W and 64 °C max per GPU, instead of 250 W and 72 °C;
- **fits 262k context on a single V100.**

For interactive use on V100 it is the most pleasant model tested here.

## llama3.3:70b and deepseek-r1:70b (dense 70 B, Q4_K_M, 43 GB)

These models need **both GPUs**, so the 1-GPU cases were skipped with `-TwoGpuOnly`. The two models share the Llama-3 70B architecture and gave **identical** speed numbers.

| Config | Context | VRAM (both GPUs) | Short gen | Long prompt prefill | Gen after long prompt |
|---|---|---|---|---|---|
| 2 GPUs | 8k | 43.0 GB | **15.7 tok/s** | 523 tok/s | 15.3 tok/s |
| 2 GPUs | 32k | 50.0 GB | 15.8 | 431 (17k tokens in 39 s) | 14.2 |
| 2 GPUs | 64k | **60.2 GB** (31.6 + 30.8 GB, nearly full) | 15.7 | 370 (34k tokens in 91 s) | 12.9 |
| 2 GPUs, FA + q8 KV | 64k | 51.1 GB | 15.2 | 334 | **9.9** |

| Parallel, 4 concurrent requests, 8k ctx | Total |
|---|---|
| 2 GPUs spread, `NUM_PARALLEL=4` | 37.5 tok/s (about 10 tok/s per request) |
| same, sustained 300 s | 36.6 tok/s |

Notes:

- **Context limit:** 64k is about the maximum with f16 KV cache. 128k does not fit, because the KV cache alone would be about 40 GB.
- **FA + q8 KV** frees 9 GB, enough for more context, but costs 23 % generation speed.
- **Long-prompt length:** the Llama tokenizer packs the synthetic log text into fewer tokens than Qwen's, so the "long prompt" filled about 50 % of the context instead of 70 %.
- **15–16 tok/s** is readable for a single user, but about 2.6× slower than the 27B and 4× slower than the 35B MoE.
- **Thermals:** max 71 / 67 °C. GPU power peaks 250–281 W during prefill.

### Loading big models from a network share

| | Load time |
|---|---|
| 43 GB model from a 1 GbE SMB share | about 7 min |
| same model from local NVMe | **37 s** |

Ollama's default **`OLLAMA_LOAD_TIMEOUT` is 5 minutes**. Above that, the load from the network fails with HTTP 500 "timed out waiting for llama-server to start". Either:

- raise the timeout (`OLLAMA_LOAD_TIMEOUT=30m`; the benchmark script sets it), or
- copy the models you use often to a local disk. [`../tools/Copy-OllamaModel.ps1`](../tools/Copy-OllamaModel.ps1) copies a model's manifest and blobs from one models directory to another.

## Summary: which model on 2× V100

| Model | Fits on | Speed (1 user) | Best throughput (4 users) | Max GPU temperature / power |
|---|---|---|---|---|
| qwen3.5:4b | 1 GPU | 68 tok/s | 142 tok/s (2 instances) | 69 °C / 250 W (prefill only) |
| **qwen3.5:35b-a3b (MoE)** | **1 GPU, even at 262k** | **63 tok/s** | **113 tok/s** (2 instances) | **64 °C / 155 W** |
| qwen3.8:27b | 1 GPU up to 131k | 41–45 tok/s | 89 tok/s (2 instances) | 72 °C / 258 W |
| llama3.3:70b / deepseek-r1:70b | 2 GPUs, up to 64k | 15.7 tok/s | 37.5 tok/s | 71 °C / 281 W |

System power (IMM2 DCMI) during the 70B runs: see [`../power/`](../power/).
