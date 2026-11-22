# Drivers and software for Tesla V100 on Windows 11 (what actually works)

Volta (V100, compute capability 7.0) is at the end of NVIDIA's support window. **CUDA 13 no longer supports Volta**, and newer driver branches are dropping it too. Getting a working stack together on Windows 11 takes some trial and error, so this page lists the exact combination running on this machine.

> NVIDIA's driver and CUDA installers **may not be redistributed**, so they are not in this repository. Download them from NVIDIA directly (links below). If a version disappears from the main download page, check NVIDIA's driver archive and the CUDA Toolkit archive.

## Working versions on this machine

| Component | Version | Notes |
|---|---|---|
| OS | Windows 11 Pro 25H2 (build 26200) | **unsupported hardware**, installed with the requirement checks removed (see below). The data-center driver installs fine on Windows 11 |
| NVIDIA driver | **560.81** data-center driver (reports CUDA 12.6) | GPUs in **TCC** mode |
| GPU VBIOS | 88.00.7E.00.03 | both cards |
| CUDA Toolkit | **12.6** (nvcc 12.6.20) | only needed to *compile* CUDA code; Ollama and the gpu-test script do not need it |
| CUDA 13.1 | installed, **unusable** | CUDA 13 has no sm_70 (Volta) target. Do not bother installing it for V100 |
| Visual Studio | 2022 Professional / 2026 Community | needed by nvcc on Windows (MSVC host compiler) |
| Nsight Compute / Systems | 2024.3 / 2024.4 | optional profiling |
| Ollama | 0.40.17 | ships its own CUDA 12 and 13 runtimes and picks the CUDA 12 one for Volta automatically |
| Python | 3.15 (gpu-test script, standard library only) | for PyTorch see below |

## Windows 11 on unsupported hardware

The x3650 M5 is **officially not supported by Windows 11**:

- **CPU:** the Xeon E5-2698 v3 (Haswell-EP) is not on Microsoft's supported CPU list.
- **TPM 2.0 / Secure Boot:** these requirements are not met in this configuration. Secure Boot is **off**; the server boots in UEFI mode.

Windows 11 Pro was installed anyway, with the **hardware requirement checks removed** during setup. It runs fine:

- **Version:** currently Windows 11 Pro **25H2, build 26200.10075**. Cumulative updates install normally.
- **Version string:** `winver` shows Windows 11, but the registry value `ProductName` still says "Windows 10 Pro". This is a known Windows quirk and harmless.

Common ways to skip the checks at install time:

- **Rufus:** when you write the USB installer, tick *"Remove requirement for 4GB+ RAM, Secure Boot and TPM 2.0"*.
- **Registry during setup:** in Windows Setup press Shift+F10, run `regedit`, and create `HKLM\SYSTEM\Setup\LabConfig` with the DWORD values `BypassTPMCheck=1`, `BypassSecureBootCheck=1` and `BypassCPUCheck=1`.

<!-- TODO: which method was used on this server -->

> Running Windows 11 on unsupported hardware is at your own risk. Microsoft does not guarantee updates for such systems. **Feature updates** (e.g. a future 26H2) may refuse to install and may need the same bypass again. Cumulative monthly updates have worked so far.

Why Windows and not Linux? It was simply the requirement for this machine. Everything here also maps to Linux:

- **Fan control:** `ipmitool raw 0x3a 0x07 …`.
- **GPU sensors:** `nvidia-smi`.
- **Ollama:** same environment variables.

## Step by step

### 1. BIOS and IMM2

Install the GPUs. See [hardware-and-cabling.md](hardware-and-cabling.md) for power and placement.

<!-- TODO: UEFI settings (MMIO / Above 4G, PCIe), if any had to be changed -->

The Microsoft IPMI driver is loaded automatically on this server. The [fan-control](../fan-control/) needs it. Check it with:

```powershell
Get-CimInstance -Namespace root/wmi -ClassName Microsoft_IPMI
```

**Install the fan control before you put load on the GPUs.** Otherwise a passive V100 overheats in minutes.

### 2. NVIDIA data-center driver

Get it from <https://www.nvidia.com/Download/index.aspx> with these selections:

- **Product type:** Data Center / Tesla
- **Product series:** V-Series
- **Product:** Tesla V100
- **OS:** Windows 11
- **CUDA toolkit:** 12.x

The download page labels the driver with a CUDA version, e.g. "CUDA 12.6". That is the highest CUDA runtime the driver supports, not something it installs.

- Choose a **12.x** driver. A driver that reports CUDA 13 is fine for Ollama's CUDA-12 runtime as long as it still lists the V100. A CUDA-13 *toolkit* is still useless for Volta.
- Run a **Custom / clean** install. You do not need GeForce Experience or the other extras.
- After a reboot, `nvidia-smi` should list both cards. `Driver Model: TCC` is the default for Teslas on Windows; switch with `nvidia-smi -i <id> -dm 1` and reboot.
- In TCC mode the cards are compute-only. Windows uses the onboard Matrox / Microsoft Basic Display for video, which is correct.

### 3. Verify and harden

```powershell
nvidia-smi                                          # both GPUs, driver, CUDA version
nvidia-smi -q -d ECC,PAGE_RETIREMENT,PERFORMANCE    # ECC state, retired pages, throttle reasons
nvidia-smi -e 1                                     # (admin) enable ECC on all cards, then reboot
```

- **ECC:** on this machine one card had ECC enabled and the other disabled, probably from the previous owner. Making it consistent is recommended. With ECC on, you lose about 6 % of VRAM, but memory errors are corrected and counted.
- **Health check:** run the [gpu-test](../gpu-test/) gentle health test next. It checks retired pages, the PCIe link, VRAM and compute correctness.
- **PCIe link generation:** at idle `nvidia-smi` reports Gen2 or Gen1 because of PCIe power saving. Under load the link runs at Gen3 x16; gpu-test measures 12–13 GB/s.

### 4. CUDA Toolkit 12.6 (only if you compile CUDA code)

Download it from <https://developer.nvidia.com/cuda-12-6-0-download-archive>.

- Install Visual Studio with the "Desktop development with C++" workload **first**, so the CUDA VS integration gets installed.
- For Volta, compile with `-arch=sm_70`.
- `cublas64_12.dll` and the other runtime DLLs are in `C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12.6\bin`.
- If CUDA 13 is installed next to 12.6, check `CUDA_PATH`, and make sure the v12.6 `bin` comes first in `PATH`.

### 5. Ollama

Install Ollama for Windows. Nothing else is needed, because Ollama brings its own CUDA runtime.

- Look in `%LOCALAPPDATA%\Ollama\server.log` for `library=CUDA compute=7.0` once per GPU.
- The best settings for 1 vs 2 GPUs are in [ollama-benchmark](../ollama-benchmark/).
- **Models on a network share.** Set the user environment variable `OLLAMA_MODELS` to the UNC path. The Ollama app also stores its own "models" path in its settings and overrides the environment variable with it. Set **`OLLAMA_NOPRUNE=1`**: otherwise Ollama deletes unreferenced and `-partial` blobs at startup, including other machines' running downloads.

### 6. Python / PyTorch (notes)

- [gpu-test](../gpu-test/) needs **only** the Python standard library, and works with any recent Python.
- For PyTorch on Volta, use a build whose CUDA version still includes `sm_70`. **CUDA 12.x wheels, not CUDA 13.**
  - Recent PyTorch releases have been dropping older architectures from some of their CUDA builds.
  - Use a Python version that PyTorch publishes wheels for. Brand-new Python versions usually lag behind.
  - Verify after installing:

    ```python
    import torch
    print(torch.__version__, torch.version.cuda, torch.cuda.is_available())
    print(torch.cuda.get_arch_list())      # must contain 'sm_70'
    print(torch.cuda.get_device_name(0))
    ```

  - If `sm_70` is missing, you get "no kernel image is available for execution on the device". Pick an older PyTorch or another CUDA build.

<!-- TODO: exact working PyTorch / Python combination, once installed -->

## Common pitfalls we hit

- **CUDA 13.x on Volta:** installs fine, but compiles nothing for sm_70. Stay on 12.x.
- **Passive cooling:** the IMM2 does not see the GPU temperature, so the card throttles or shuts down. See [fan-control](../fan-control/).
- **`.bat` files with LF line endings:** they "do nothing" when double-clicked. Keep CRLF. This repository's `.gitattributes` enforces it.
- **PowerShell 5.1 scripts containing non-ASCII text** need a UTF-8 BOM, or they fail to parse.
