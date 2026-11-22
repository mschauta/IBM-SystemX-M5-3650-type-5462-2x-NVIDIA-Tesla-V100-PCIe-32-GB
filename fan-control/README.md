# GPU-driven fan control for IBM/Lenovo System x3650 M5 (IMM2)

## Why

The x3650 M5's IMM2 sets fan speed from its own sensors (CPU, VR, DIMM, PCH, inlet). It **cannot see the temperature of add-in GPUs**. A passive Tesla V100 depends entirely on chassis airflow, so under load the card heats up while the fans stay at idle (about 4 000 RPM). In our test, a V100 limited to 150 W reached 80 °C in a few minutes.

`LenovoGpuFanControl.ps1` reads GPU temperatures from `nvidia-smi` and raises the fans of the side where the GPU sits. It uses an OEM IPMI command sent **in-band** through the Windows IPMI driver (WMI `root\wmi : Microsoft_IPMI`). It needs no network, no IMM password and no `ipmitool`.

## What it does

### Two fan zones, one per CPU side

Measured with `-Mode ZoneProbe`:

| Zone | Fans | Side | GPU | Also cools |
|---|---|---|---|---|
| 1 | Fan 1–3 | CPU1 | GPU on riser 1 (PCI bus `07`) | CPU1 VR, DIMM AB/CD |
| 2 | Fan 4–6 | CPU2 | GPU on riser 2 (PCI bus `87`) | CPU2 VR, DIMM EF/GH |

Each GPU is assigned to a zone by its PCI bus number: bus < `0x80` → zone 1, otherwise zone 2.

### Per-zone control

- **Cool zone:** while its GPU is below `EngageTemp` (52 °C), the zone stays in **factory automatic** mode.
- **Taking over:** at 52 °C or more, the script takes the zone into manual mode and follows the curve `52:40,58:50,64:65,70:80,75:100` (°C : fan %, linear interpolation).
- **Cross-side help:** the other side's GPU also raises this zone, by `CrossPercent` (35 %) less than its own curve value. The two airflows partly mix in the middle.
- **Fan floor:** the script never sets a zone slower than its factory speed. This floor is taken when the zone has been on automatic for at least 90 s, otherwise a 4 000 RPM idle value is used.
- **Ramping:** speed goes up immediately and comes down by at most 3 % per cycle (5 s).
- **Giving back:** when the GPU stays below `ReleaseTemp` (47 °C) for 120 s, the zone returns to factory automatic.

### Fail-safes (to 100 %)

| Condition | Effect |
|---|---|
| GPU ≥ `GpuPanicTemp` (82 °C) | that zone to 100 % |
| CPU VR > 70 °C, DIMM VR > 75 °C on a side | that zone to 100 % |
| PCH > 80 °C | both zones to 100 % |
| `nvidia-smi` fails, fewer than `ExpectedGpus` GPUs, or a zone without a GPU | both zones to 100 % |
| a protection sensor unreadable for 3 cycles | that zone to 100 % |
| IPMI command fails | retries at 100 %; after 12 consecutive failures the script exits, and the scheduler restarts it |
| script stopped or exits normally | factory automatic restored for both zones |
| script hangs (no heartbeat for 90 s) | the **watchdog task** kills it and restores factory automatic |

All of these were tested with the built-in fault simulation (`-Simulate GpuFail|GpuMissing|SensorMissing|IpmiSetFail|Hang`).

## The IPMI commands

They are the same commands you can send with `ipmitool raw` over the network:

```
# manual: zone (1|2), duty 0-255, 0x01
ipmitool raw 0x3a 0x07 0x01 0x99 0x01      # zone 1 at ~60 %
# back to factory automatic
ipmitool raw 0x3a 0x07 0x01 0x12 0x00      # zone 1
ipmitool raw 0x3a 0x07 0x02 0x12 0x00      # zone 2
```

Fan RPM and temperatures are read from the SDR (`Get SDR` / `Get Sensor Reading`). The script only allows the read-only commands it needs and this one OEM command.

Note: after you return a zone to automatic, the IMM2 ramps the fans down **slowly** (about 1 minute).

## Usage

Run as Administrator. The easiest way is `gpu_ventilator.bat`, which elevates itself and shows a menu.

```powershell
.\LenovoGpuFanControl.ps1 -Mode Status      # read-only: GPUs, fans, temps, zone state
.\LenovoGpuFanControl.ps1 -Mode ZoneProbe   # each zone to 100 % for 45 s, then back (verifies mapping)
.\LenovoGpuFanControl.ps1 -Mode Run         # foreground control (Ctrl+C, then run -Mode Restore)
.\LenovoGpuFanControl.ps1 -Mode Install     # install + start background tasks (SYSTEM)
.\LenovoGpuFanControl.ps1 -Mode Stop        # graceful stop, factory auto restored, task disabled
.\LenovoGpuFanControl.ps1 -Mode Start       # enable + start again
.\LenovoGpuFanControl.ps1 -Mode Uninstall   # remove tasks, restore factory auto
.\LenovoGpuFanControl.ps1 -Mode Restore     # emergency: both zones back to factory auto
```

`-Mode Install` creates two scheduled tasks running as **SYSTEM**:

- `LenovoGpuFanControl` runs at startup and is re-triggered every 5 minutes. A mutex guarantees a single instance, so the re-trigger acts as a restart if the controller has died.
- `LenovoGpuFanControl-Watchdog` runs every minute and checks the heartbeat file. If the heartbeat is stale, it kills the controller and restores factory auto.

The script writes these logs to `logs\`:

- `fan_run_YYYYMMDD.txt`: events, plus a status line every 60 s.
- `fan_run_YYYYMMDD.csv`: one row every 5 s with GPU temperatures, zone state, %, RPM, VR and PCH temperatures.
- `fan_watchdog_YYYYMMDD.txt`: watchdog actions.

Logs are kept for 14 days.

All thresholds are parameters (see the `param()` block). The curve and thresholds above are what we validated on this machine.

## Measured results

| Test | Without control | With control |
|---|---|---|
| V100 at 150 W (gpu-test ramp) | 80 °C, test aborted | 66–69 °C |
| Both GPUs loaded at once | – | 67 / 65 °C, zone 1 72 %, zone 2 68 % |
| Ollama benchmark, 2 h (peaks 250–269 W) | – | max 72 / 66 °C, zone 1 max 88 % (13 400 RPM), zone 2 max 70 % |

VR, DIMM and PCH temperatures stayed at 39, 31 and 43 °C or lower.

**Known behaviour:** when a model stays loaded in VRAM, an idle V100 can sit at 47–50 °C. Zone 1 then stays in manual mode at the 30–40 % floor (about 6 000 RPM). If you prefer the factory idle speed, lower `-ReleaseTemp` (e.g. 45) or raise `-EngageTemp`.

## Diagnostics

`Diagnose-LenovoV100.ps1` is **read-only**. It prints the server and BIOS info, the GPU state from `nvidia-smi`, the IMM devices, and a walk of all IPMI SDR sensors with their current readings. Run it first on a new machine to see sensor names and fan layout.

> The diagnostic output contains **serial numbers**. Remove them before you post it anywhere.

## Requirements

- Windows with the Microsoft IPMI driver. It is present by default on server hardware: check that `Get-CimInstance -Namespace root/wmi -ClassName Microsoft_IPMI` returns an object.
- NVIDIA driver with `nvidia-smi`.
- Windows PowerShell 5.1. The `.ps1` files are UTF-8 **with BOM** and the `.bat` files use **CRLF**. Keep it that way if you edit them, or they break.
