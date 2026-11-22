# Measured system power (IMM2)

`Read-ServerPower.ps1` reads the **whole-system input power** from the IMM2 via in-band IPMI. It is read-only. It reads two sources:

- the **DCMI Get Power Reading** command;
- every SDR sensor reported in watts (on this machine: `Avg Power`).

Next to those it logs each GPU's own power, temperature and utilization from `nvidia-smi`.

```powershell
# administrator PowerShell
.\Read-ServerPower.ps1                 # one reading
.\Read-ServerPower.ps1 -Seconds 3600   # sample every 5 s for an hour, then print a summary
```

The script writes `logs\power_<timestamp>.txt` and `.csv`. Two runs are included in [`results/`](results/).

The IMM2 on this server provides **only the total system power**. It has no per-PSU wattage sensors.

## Results: IBM x3650 M5, 2 × E5-2698 v3, 192 GB, 8 × 10 TB SAS, 4 × NVMe, 2 × V100

| State | System power (avg / max) | Both GPUs (nvidia-smi) |
|---|---|---|
| Idle, GPUs idle (models loading or unloaded) | **334 W** avg (296–350 W) | about 80 W (2 × 40 W) |
| 70B model, short generation | 573 / 588 W | about 120 W avg |
| 70B model, long prompt (64k ctx, prefill + generation) | **705 / 771 W** | about 245 W avg, peaks over 330 W |
| 70B, 4 parallel requests, sustained 5 min | 592 / 631 W | about 190 W avg |
| **Highest reading** | **787 W** | |

The "rest of the system" (total minus the GPUs) rises from about 255 W at idle to about 455 W under LLM load, for two reasons:

- **Fans:** the [fan-control](../fan-control/) raises them to 60–90 %. These are dual-rotor, high-RPM fans and draw a lot.
- **CPUs:** Ollama keeps CPU threads busy during inference.

The DCMI reading and the `nvidia-smi` samples are not taken at the same instant, so the split between GPU and rest is approximate.

### What this means for the PSUs (2 × 900 W)

- The highest measured draw, **787 W**, stays **inside a single 900 W supply**, so redundant (N+1) operation works for this LLM workload, but with only about 110 W of headroom.
- A heavier GPU workload (both V100 at a sustained 250 W, e.g. training) plus CPU load would exceed 900 W. In that case redundancy is lost, and the PSUs share the load.
- Add the spin-up of 8 HDDs at power-on, and do not plan this build with a smaller PSU pair.
