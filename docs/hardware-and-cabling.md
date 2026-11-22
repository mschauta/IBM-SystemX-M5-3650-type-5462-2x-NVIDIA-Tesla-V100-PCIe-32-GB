# Hardware and GPU power cabling

> **Work in progress.** Photos and the exact cable and adapter details will be added. This page answers the common Reddit questions: can it be done with one cable, which connector, which adapter.

## The server

- **Model:** IBM/Lenovo System x3650 M5, machine type 5462, 2U, 2 sockets.
- **GPU placement:** one Tesla V100 PCIe 32 GB in **riser 1** (CPU1, PCI bus `07`) and one in **riser 2** (CPU2, PCI bus `87`).
- **Airflow:** 6 dual-rotor hot-swap fans in two zones: fans 1–3 on the CPU1 side, fans 4–6 on the CPU2 side. See [fan-control](../fan-control/).

<!-- TODO photos: server overview, riser 1, riser 2, GPU seated, airflow path -->

## GPU power

The Tesla V100 PCIe has **one 8-pin power connector on the rear edge of the card**. On the Tesla PCIe cards (K80, P40, P100, V100) this connector uses the **8-pin CPU / EPS-12V pinout, not the 8-pin PCIe pinout**. A standard PCIe 8-pin plug can physically go in only with force, and it puts 12 V and ground on the wrong pins.

> Always check the pinout of your exact cable with a multimeter before you power on. A wrongly wired adapter can destroy the card or the server's power distribution board.

Maximum board power is 250 W: 75 W from the slot plus up to 175 W through the 8-pin connector.

### In this build

<!-- TODO: fill in -->

- Power source on the server side (riser / power board connector):
- Cable or adapter used, part number:
- **One cable per GPU?**
- Pinout diagram / photo:
- Observed: both GPUs ran at their 250 W limit during prompt processing with no power brake or throttling (`nvidia-smi` throttle reasons clean).

<!-- TODO photos: connector on the server side, adapter, connector on the GPU, pinout -->

## BIOS and firmware notes

<!-- TODO: UEFI settings used (Above 4G decoding / MMIO, PCIe slot settings, power profile), IMM2 and UEFI firmware versions -->

- Windows: install the NVIDIA **data-center driver** (560.81 here). The cards run in **TCC** mode, so they are compute-only with no display.
- CUDA 12.x is the last series that supports Volta (CC 7.0). CUDA 13 does not.
