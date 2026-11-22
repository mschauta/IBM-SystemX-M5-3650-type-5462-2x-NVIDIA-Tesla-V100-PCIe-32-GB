# Gentle Tesla V100 health test

`gpu_alapteszt.py` checks a used or refurbished V100 **before you stress it**. It needs only the Python standard library and the NVIDIA driver (`nvcuda.dll`, `nvml.dll`, via `ctypes`). It does not need CUDA Toolkit, PyTorch or pip packages: the kernels are PTX, JIT-compiled by the driver.

It is **not** a burn-in. Every load phase is duty-cycle limited and aborts automatically at a temperature or power limit.

## What it checks

1. **Health counters:** sensors, ECC counters, retired pages, PCIe link (generation and width), throttle reasons.
2. **Power limit:** optionally lowers it to 150 W for the test and restores it afterwards.
3. **CUDA:** init, device info, JIT compilation of its own PTX kernels.
4. **VRAM:** fills most of the free memory with patterns and verifies them.
5. **PCIe:** host↔GPU copies with integrity check and bandwidth.
6. **Compute correctness:** deterministic integer and FP32 FMA kernels, checked bit-exact against the CPU.
7. **Light load:** short load phases, or a stepped ramp (`--ramp`: 150 → 200 → 250 W) with live temperature and power monitoring and an automatic stop.
8. **Post-check:** ECC counters and PCIe replay counter compared to the start, then a summary and a log file.

## Usage

Run as Administrator to allow power-limit changes. `gpu_teszt.bat` gives a menu and asks which GPU to test.

```
python gpu_alapteszt.py                 # default gentle run on GPU 0
python gpu_alapteszt.py --gpu 1         # second GPU
python gpu_alapteszt.py --gpu all       # every GPU, one after another, separate logs
python gpu_alapteszt.py --ramp          # + stepped load 150 / 200 / 250 W
python gpu_alapteszt.py --ramp-only --ramp-steps 150,175,200 --ramp-seconds 90
python gpu_alapteszt.py --skip-load     # no load phases at all
python gpu_alapteszt.py --max-power 130 # stricter emergency power limit
```

## Example result (V100-PCIE-32GB, with the fan control running)

```
[ OK ] Idle temperature            - 45 °C
[ OK ] Retired pages               - 0
[ OK ] Device                      - Tesla V100-PCIE-32GB, CC 7.0, 80 SM, 31.9 GiB
[ OK ] Compute correctness         - all threads match the CPU reference
[ OK ] FP32 FMA kernel (bit-exact) - 6 threads x 8 chains x 2000 steps match
[ OK ] Step 150 W                  - 0 errors, avg 150 W, max 63 °C
[ OK ] Step 200 W                  - 0 errors, avg 163 W, max 67 °C (kernel tops out here)
[ OK ] Step 250 W                  - 0 errors, avg 162 W, max 67 °C
[ OK ] PCIe signal quality         - +0 replays
RESULT: ALL OK
```

The simple FMA kernel cannot pull more than about 165 W. Real LLM prompt processing (cuBLAS / tensor cores) reaches the full 250 W; see `../ollama-benchmark`.

Without the GPU fan control, the same card reached **80 °C at the 150 W step** and the test stopped itself.

> Output is in Hungarian. `ECC kikapcsolva` = ECC disabled. Enable it with `nvidia-smi -e 1` and a reboot if you want the ECC counters checked.
