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

## Firmware: the versions in use, and why

| Component | Firmware |
|---|---|
| UEFI (BIOS) | **TCE156A 3.70** (2022-04-14) |
| IMM2 (BMC) | **3.75** (IPMI firmware revision; IPMI 2.0, manufacturer ID 77 = Lenovo). The full build ID (TCOO…) is shown in the IMM2 web UI |
| Tesla V100 VBIOS | 88.00.7E.00.03 (both cards) |
| HGST HUH721010AL5200 (10 TB SAS) | A384 |
| Samsung 970 EVO Plus 2 TB | 4B2QEXM7 |

<!-- TODO: full IMM2 build ID, ServeRAID M5210 firmware, X520 / Broadcom NIC firmware (IMM2 web UI → Server Firmware, or OneCLI / storcli) -->

> **Why these versions:** on this server, **newer IBM/Lenovo firmware releases caused fan-control problems**: the fans ramped up and stayed loud. The versions above run stable and quiet, so the server deliberately stays on them.
>
> The [fan-control](../fan-control/) OEM IPMI command (`0x3A 0x07`), the fan-zone mapping and the sensor names were developed and tested **on exactly this UEFI 3.70 / IMM2 3.75 combination**. Other firmware may behave differently. Run `-Mode Status` and `-Mode ZoneProbe` first.

<!-- TODO: which newer UEFI / IMM2 version showed the loud-fan behaviour -->

### Windows drivers in use

| Device | Driver |
|---|---|
| Tesla V100-PCIE-32GB | NVIDIA 560.81 (32.0.15.6081) |
| ServeRAID M5210 (AVAGO MegaRAID SAS) | megasas2i 6.714.22.0 |
| Intel X520-2 | 4.1.143.0 |
| Broadcom NetXtreme GbE (onboard) | 214.0.0.0 |
| Lenovo IMM2 PBI PCI Mailbox | 1.0.1.2015 |
| IPMI | Microsoft Generic IPMI Compliant Device (inbox) |
| NVMe | Microsoft inbox `stornvme` |

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

The "Nominal max" column is a datasheet estimate.

### Measured whole-system power (IMM2 DCMI)

| State | System power |
|---|---|
| Idle (GPUs idle, fans settled) | **304 W** avg (290–315 W) |
| 70B LLM, generating | about 575–590 W |
| 70B LLM, long prompt (prefill) | about **705 W** avg, 771 W max |
| 70B LLM, 4 parallel users, sustained | 592 W avg, 631 W max |
| **Highest reading** | **787 W** |

- **One supply is enough for this workload:** LLM inference stays within a single 900 W PSU, but with only about 110 W headroom.
- **Heavier loads exceed it:** a sustained full GPU load, e.g. training, plus CPU load would go over 900 W.

Details and the measuring script are in [`../power/`](../power/).

<!-- TODO: PSU redundancy mode used, PSU part number -->

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

The installed cable was purchased under the listing title **"35cm 8pin to 8pin Power Adapter Cable for IBM X3650 M5 to GPU video card"**.

- **Server-side power source:** the x3650 M5 motherboard's GPU auxiliary-power connector (as reported by the builder).
- **Cable:** a 35 cm, sleeved 8-pin-to-8-pin GPU power adapter sold specifically for the IBM x3650 M5.
- **Modification:** none. The cable was installed as supplied; no repinning, splicing or connector rewiring was performed.
- **GPU-side connection:** the 8-pin auxiliary-power socket of a Tesla V100 PCIe 32 GB.
- **Cable part number:** not confirmed. The marketplace listing title is not a verified IBM/Lenovo FRU identifier.
- **Quantity/routing:** the exact number of cables and the complete power-distribution routing have not yet been independently documented.
- **Electrical verification:** a full end-to-end pinout diagram or multimeter pin map has not been published. The photos show connector shapes and wire colors, **not** a verified electrical pin assignment.
- **Observed operation:** both GPUs ran at their 250 W limit during prompt processing without reported power-brake or throttling events (`nvidia-smi` throttle reasons clean).

The builder supplied four vendor photographs showing the adapter cable and its connectors. These photos are pending addition to the repository.

> **Safety:** Do not assume an arbitrary 8-pin-to-8-pin cable is electrically interchangeable with this adapter. Inspect the exact motherboard and GPU connector pinouts and verify 12 V, grounds, continuity and cable current rating before connecting power. A successful installation does not establish compatibility of lookalike adapters.

<!-- TODO: add vendor cable photos, verify printed part number/FRU if available, document exact installed cable count and measured connector pinout -->

## BIOS and firmware notes

<!-- TODO: UEFI settings used (Above 4G decoding / MMIO, PCIe slot settings, power profile), IMM2 and UEFI firmware versions -->

- Windows: install the NVIDIA **data-center driver** (560.81 here). The cards run in **TCC** mode, so they are compute-only with no display.
- CUDA 12.x is the last series that supports Volta (CC 7.0). CUDA 13 does not.
