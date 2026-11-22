# IBM / Lenovo System x3650 M5 (type 5462) + 2× NVIDIA Tesla V100 PCIe 32 GB

A home-lab build: an old 2U Intel Xeon server running two passively cooled Tesla V100 32 GB cards for local LLM inference (Ollama) under Windows 11 Pro.

This repository contains:

| Folder | What it is |
|---|---|
| [`fan-control/`](fan-control/) | **GPU-temperature-driven fan control for the IMM2.** The stock firmware ignores add-in GPU temperatures, so passive V100s overheat. This script reads the GPUs and raises the fans per side via in-band IPMI. It runs as a background service with a watchdog. |
| [`gpu-test/`](gpu-test/) | A gentle V100 health test (VRAM patterns, PCIe bandwidth and integrity, bit-exact compute check, stepped 150/200/250 W load with thermal cut-off). It needs only Python and the NVIDIA driver. |
| [`ollama-benchmark/`](ollama-benchmark/) | Ollama benchmark: 1 GPU vs 2 GPUs, context size, Flash Attention and q8 KV cache, parallel serving, with temperature, power and fan logging. Results are included. |
| [`docs/hardware-and-cabling.md`](docs/hardware-and-cabling.md) | Full hardware configuration, power budget, GPU power cabling and photos. *(work in progress)* |
| [`docs/drivers-and-software.md`](docs/drivers-and-software.md) | **Working driver, CUDA and software versions** for V100 on Windows 11 (driver 560.81, CUDA 12.6, Ollama), install order and pitfalls. Volta is no longer supported by CUDA 13. |

> Console and log messages in the scripts are in **Hungarian**. The code, parameters and these documents are in English.

## Hardware

| | |
|---|---|
| Server | IBM System x3650 M5, machine type 5462 (5462-B2G), UEFI 3.70, IMM2 |
| CPUs | 2 × Intel Xeon E5-2698 v3 (16C/32T each, 2.3 GHz, 135 W) |
| RAM | 24 × 8 GB DDR4 RDIMM = 192 GB (all slots, runs at 1600 MT/s) |
| GPUs | 2 × NVIDIA Tesla V100-PCIE-32GB (passive, 250 W), one per CPU riser, PCIe Gen3 x16 (12–13 GB/s measured) |
| Storage | ServeRAID M5210 + 8 × 10 TB SAS HDD; 4 × Samsung 970 EVO Plus 2 TB NVMe |
| Network | 4 × 1 GbE onboard, Intel X520-2 dual 10 GbE SFP+, Wi-Fi |
| Fans | 6 hot-swap dual-rotor fans in 2 zones: about 4 000 RPM at factory idle, about 15 000 RPM at 100 % |
| Power | 2 × 900 W hot-swap PSUs (see the [power budget](docs/hardware-and-cabling.md#power-budget)) |
| OS / driver | Windows 11 Pro, NVIDIA 560.81 (TCC mode), CUDA 12.6 (CUDA 13.x does not support Volta) |

Full component list, slot placement and power budget: [docs/hardware-and-cabling.md](docs/hardware-and-cabling.md).

## The problem in one picture

Without the fan control, the IMM2 keeps the fans at idle (about 4 000 RPM) because no *system* sensor gets warm. A passive V100 at only 150 W reached **80 °C** within minutes, and the test aborted itself.

With [`fan-control`](fan-control/), the same load holds at **66–69 °C**. Under real LLM inference (prompt processing peaks at 250–269 W), the GPUs stayed at **≤ 72 °C**.

## Key LLM results (Ollama 0.40, Q4_K_M)

| Model | Best single-user setup | Generation | Best multi-user setup (4 concurrent) |
|---|---|---|---|
| qwen3.5:4b | 1 GPU | 68 tok/s | 2 instances, 1 per GPU: **142 tok/s** total |
| qwen3.8:27b | 1 GPU (≤ 131k ctx) | 41–45 tok/s | 2 instances, 1 per GPU: **89 tok/s** total (75 tok/s sustained) |
| qwen3.8:27b @ 262k ctx | 2 GPUs (does not fit one) | 40 tok/s | – |

Takeaways for V100 + Ollama:

- **Splitting a model that fits on one GPU makes a single request slower, not faster** (layer split is sequential). The second GPU only helps prompt processing on long prompts.
- **For several users, run one Ollama instance per GPU** (`CUDA_VISIBLE_DEVICES=0` / `1`, different ports). This gives 1.4–1.7× the throughput of one instance spread over both cards.
- **Flash Attention + q8_0 KV cache saves VRAM but costs 12–35 % generation speed at long context** on Volta. Use it only to make something fit.

Full tables, thermal data and the recommended configuration are in [`ollama-benchmark/`](ollama-benchmark/).

## Disclaimer

The fan-control script sends **OEM IPMI commands** to the server's management controller. It was developed and tested on *one* x3650 M5 (5462) with IMM2. Other models and firmware may map fan zones differently. Run `-Mode Status` and `-Mode ZoneProbe` first, keep an eye on temperatures, and know how to restore automatic control (`-Mode Restore`). Use at your own risk.

## License

MIT, see [LICENSE](LICENSE).
