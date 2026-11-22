# Hardware and GPU power cabling

> **Work in progress.** Photos and the exact cable and adapter details will be added. This page answers the common Reddit questions: can it be done with one cable, which connector, which adapter.

## Full configuration

| Component | Details |
|---|---|
| Server | IBM System x3650 M5, machine type **5462** (model 5462-B2G), 2U, 2 sockets |
| Firmware | UEFI TCE156A **3.70** (2022-04). Management: IMM2 |
| CPUs | 2 × **Intel Xeon E5-2698 v3** (Haswell-EP), 16 cores / 32 threads each, 2.3 GHz, 135 W TDP each. Total 32 cores / 64 threads |
| Memory | **24 × 8 GB DDR4 RDIMM = 192 GB** (19 × Micron 18ASF1G72PZ-2G1A2 + 5 × Samsung M393A1G40DB0-CPB), all 24 slots populated. Rated 2133 MT/s, **runs at 1600 MT/s** because 3 DIMMs per channel force the lower speed |
| GPUs | 2 × **NVIDIA Tesla V100-PCIE-32GB** (passive, 250 W each). GPU0 on PCI bus `07` (CPU1 side), GPU1 on bus `87` (CPU2 side) |
| RAID controller | **IBM ServeRAID M5210** (Avago/LSI SAS3108, PCI ID `1000:005D`, subsystem `1014:0454`), on CPU1 |
| HDDs | **8 × HGST Ultrastar He10 10 TB SAS** (HUH721010AL5200), 3.5", 7200 rpm. Presented as 4 volumes of 18.6 TB |
| NVMe SSDs | **4 × Samsung 970 EVO Plus 2 TB**, on PCIe-switch adapter cards: 2 on the CPU1 side (bus 2), 2 on the CPU2 side (bus 130). One is the Windows boot drive |
| External | 1 × 512 GB NVMe in a USB enclosure (ASMedia ASM236x) |
| LAN | 4 × Broadcom NetXtreme 1 GbE (onboard), **Intel X520-2** dual-port 10 GbE SFP+ (CPU2 side), IMM2 dedicated management port + IMM LAN-over-USB |
| Wi-Fi | ASUS PCE-AC88 (802.11ac, PCIe) |
| Fans | **6 × hot-swap dual-rotor fans** (2 motors each, 12 tach sensors). Zone 1 = fans 1–3 (CPU1 side), zone 2 = fans 4–6 (CPU2 side). Factory idle about 4 000 RPM, 100 % about 15 000 RPM. See [fan-control](../fan-control/) |
| Power supplies | **2 × 900 W** hot-swap |
| OS | Windows 11 Pro (build 26200), NVIDIA data-center driver 560.81 (TCC), CUDA 12.6 |

<!-- TODO: RAID layout of the 8 HDDs (RAID level / virtual drives), NVMe adapter card model, PSU part number / efficiency rating -->

## Power budget

This matters if you plan the same build. The power supplies are **2 × 900 W**.

- **Redundant mode:** the whole system has to fit into **one** 900 W supply.
- **Non-redundant mode:** the two supplies share the load and can deliver more, but losing one supply under full load shuts the server down.

| Consumer | Nominal max | Measured here |
|---|---|---|
| 2 × V100 | 2 × 250 W = 500 W | peaks 250–269 W per GPU during LLM prompt processing; 100–220 W while generating; about 40 W each at idle |
| 2 × E5-2698 v3 | 2 × 135 W = 270 W | low during GPU inference |
| 24 × DDR4 RDIMM | about 70–90 W | |
| 8 × 10 TB SAS HDD | about 55–70 W (spin-up peaks are higher) | |
| 4 × NVMe + RAID + NICs | about 40–60 W | |
| 6 fans | up to about 100+ W at 100 % (dual-rotor, high-RPM) | fan-control keeps them at 30–88 % |
| **Total, everything at max** | **about 1 050–1 100 W** | |

In practice, LLM inference loads the GPUs fully only during prompt processing, while the CPUs stay mostly idle. The real draw stays well below the theoretical sum, but it can exceed one 900 W supply if CPUs and GPUs peak together.

> The numbers in the "Nominal max" column are datasheet estimates, not wall-socket measurements. To see real PSU input power, look at the IMM2 web UI (Server Power) or the IPMI power sensors.

<!-- TODO: measured wall / IMM power at idle, during LLM inference, during GPU stress; PSU redundancy mode used -->

## GPU placement and airflow

- One Tesla V100 PCIe 32 GB sits in **riser 1** (CPU1, PCI bus `07`) and one in **riser 2** (CPU2, PCI bus `87`).
- The chassis is ducted: the fans on each side mainly cool that side's CPU, DIMMs and riser. This is why the fan control works per zone.
- GPU0 on the CPU1 side consistently runs a few °C warmer than GPU1.

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
