# Hardware and GPU power cabling

> **Work in progress.** Additional photos and the remaining cable and adapter details will be added. This page answers the common Reddit questions: can it be done with one cable, which connector, which adapter.

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

![IBM System x3650 M5 with 2× NVIDIA Tesla V100 PCIe 32 GB](images/server-dual-v100.jpg)

<!-- TODO photos: riser 1 and riser 2 close-ups, airflow path -->

## GPU power

The Tesla V100 PCIe has **one 8-pin power connector on the rear edge of the card**. On the Tesla PCIe cards (K80, P40, P100, V100) this connector uses the **8-pin CPU / EPS-12V pinout, not the 8-pin PCIe pinout**. A standard PCIe 8-pin plug can physically go in only with force, and it puts 12 V and ground on the wrong pins.

> Always check the pinout of your exact cable with a multimeter before you power on. A wrongly wired adapter can destroy the card or the server's power distribution board.

Maximum board power is 250 W: 75 W from the slot plus up to 175 W through the 8-pin connector.

### In this build

Two cable sections connect the motherboard GPU power outlet to each Tesla V100:

1. **Server-side extender:** **"35cm 8pin to 8pin Power Adapter Cable for IBM X3650 M5 to GPU video card"**. It connects to the motherboard GPU power outlet and was used **without modification**.
2. **GPU adapter:** the **"Dual 8 to 8 Pin GPU Power Cable for NVIDIA Tesla V100"** Y-cable supplied with the V100. The builder removed one of its two branches and rewired the remaining branch, converting the Y-cable into a single-branch adapter.

At the GPU-side 8-pin connector, as shown in the installed-server photo, **four yellow +12 V conductors/contact positions are above four black GND conductors/contact positions** in the photographed orientation. The modified Y adapter distributes **three incoming +12 V wires to four +12 V contacts** (one wire feeds two contacts), while **four GND wires connect to four GND contacts**.

The builder modified the V100 Y adapter and left the 35 cm server-side extender unchanged. This description documents the builder's specific working assembly, not a universal 8-pin GPU cable pinout.

**Connection order:** motherboard GPU power outlet → unmodified 35 cm extender → modified single-branch V100 adapter → Tesla V100.

### Unmodified 35 cm motherboard power cable

The four photos below show the **“35cm 8pin to 8pin Power Adapter Cable for IBM X3650 M5 to GPU video card”**. This is the cable connected to the motherboard GPU power outlet. Its other end connects to the modified V100 adapter. The builder used this 35 cm cable **without modification**.

| Unmodified 35 cm cable, view 1 | Unmodified 35 cm cable, view 2 |
|---|---|
| ![Unmodified IBM x3650 M5 35 cm motherboard power cable, view 1](images/x3650-m5-35cm-power-cable-01.webp) | ![Unmodified IBM x3650 M5 35 cm motherboard power cable, view 2](images/x3650-m5-35cm-power-cable-02.webp) |

| Unmodified 35 cm cable, connectors | Unmodified 35 cm cable, overview |
|---|---|
| ![Unmodified IBM x3650 M5 35 cm motherboard power cable, connectors](images/x3650-m5-35cm-power-cable-03.webp) | ![Unmodified IBM x3650 M5 35 cm motherboard power cable, overview](images/x3650-m5-35cm-power-cable-04.jpg) |

### Original Tesla V100 Y-cable before modification

The six photos below show the **original, unmodified Y-cable supplied with the V100**, named **“Dual 8 to 8 Pin GPU Power Cable for NVIDIA Tesla V100”**. Both branches are still present. The final modified adapter is documented in the next section.

| Original Y-cable, overview 1 | Original Y-cable, overview 2 |
|---|---|
| ![Original Tesla V100 Y-cable before modification, overview 1](images/v100-original-y-cable-01.webp) | ![Original Tesla V100 Y-cable before modification, overview 2](images/v100-original-y-cable-02.webp) |

| Original single-end connector, wire entry | Original single-end connector, mating face |
|---|---|
| ![Original Tesla V100 Y-cable before modification, single-end wire entry](images/v100-original-y-cable-03.webp) | ![Original Tesla V100 Y-cable before modification, single-end mating face](images/v100-original-y-cable-06.webp) |

| Original two branch connectors, wire entry | Original two branch connectors, mating faces |
|---|---|
| ![Original Tesla V100 Y-cable before modification, two branch wire entries](images/v100-original-y-cable-04.webp) | ![Original Tesla V100 Y-cable before modification, two branch mating faces](images/v100-original-y-cable-05.webp) |

### Final modified Tesla V100 adapter used in this build

The photos below show the **modified final cable** after rewiring.

This cable started as the **“Dual 8 to 8 Pin GPU Power Cable for NVIDIA Tesla V100”** Y-cable supplied with the V100. The builder removed one branch and rewired the remaining branch.

#### Required tools and replacement contacts

The builder considers the following **essential supplies for this adapter modification**. Without a suitable crimping tool and replacement contacts, the rewiring is difficult; identifying the correct contact type can also take considerable effort. The exact product references are recorded here to make them easier to find.

| Item | Exact reference | Purpose and identification |
|---|---|---|
| Ratcheting crimping pliers | [HESTORE PLIERS-SN-58B, item 100.485.79](https://www.hestore.hu/prod_10048579.html) | Crimping tool with an **SN-58B jaw**, for attaching replacement contacts to the wires. |
| Female crimp contacts | [HESTORE MX-5556-TL (NCT420-T16F), item 100.303.93](https://www.hestore.hu/prod_10030393.html) | **Mini-Fit Jr.** female crimp contact. HESTORE lists [Molex 39-00-0039](https://www.molex.com/en-us/products/part-detail/0039000039) (**5556TL**) as the manufacturer reference, with a wire range of **24–18 AWG (0.20–0.82 mm²)**. |

Match the replacement contact to the actual wire size and connector housing, including the combined wire size if two wires share one contact. Check the finished crimp and end-to-end continuity before use.

#### Photos of the final modified adapter

![Final modified Tesla V100 adapter, connected cable sections](images/v100-modified-adapter-05.jpg)

*Final modified adapter with the cable sections connected.*

| Connector close-up, view 1 | Connector close-up, view 2 |
|---|---|
| ![Final modified Tesla V100 adapter, connector close-up 1](images/v100-modified-adapter-01.jpg) | ![Final modified Tesla V100 adapter, connector close-up 2](images/v100-modified-adapter-02.jpg) |

| Wire-entry close-up, view 1 | Wire-entry close-up, view 2 |
|---|---|
| ![Final modified Tesla V100 adapter, wire-entry close-up 1](images/v100-modified-adapter-03.jpg) | ![Final modified Tesla V100 adapter, wire-entry close-up 2](images/v100-modified-adapter-04.jpg) |

#### Final wiring concept

- **+12 V side:** 3 source wires distributed to 4 destination contacts
- **One +12 V wire is split to two connector pins**
- **Ground side:** 4 ground wires mapped to 4 ground contacts

In short:

- **3 × +12 V → 4 × +12 V**
- **4 × GND → 4 × GND**

#### Original source arrangement

Originally the cable came from **two 8-pin connectors**.
Per the builder’s description, the original +12 V / ground grouping was:

- +12 V: `(1,2)(1,2)`
- GND: `(2,2)(2,2)`

After modification, this became:

- +12 V: `(1,1,1/2,1/2)`
- GND: `(1,1,1,1)`

The grouping notation above is reproduced from the builder's description; it is not connector pin numbering or a verified pin-to-pin map.

#### Important note

This is a **custom modified cable**, not a stock off-the-shelf final wiring solution.
The photos document the physical result, but anyone reproducing this should still verify:

- end-to-end continuity
- exact pin-to-pin mapping
- polarity
- conductor gauge
- current handling capability

A wiring mistake can damage the GPU or the server.


### GPU-side 8-pin connector: photographed orientation

The annotated image below is an **orientation reference for the builder-reported final wiring**. The original-cable and modified-adapter photographs above document the before and after states.

![Tesla V100 8-pin connector orientation reference, annotated for final wiring](images/v100-8pin-annotated.png)

*GPU-side 8-pin connector, viewed straight into the mating face in the photographed orientation: upper row = 4 × +12 V (yellow), lower row = 4 × GND (black). This annotation reflects the builder's working cable arrangement for this specific build.*

Looking **straight into the mating face of the cable plug**, with the connector oriented exactly as in the supplied close-up photo:

```text
     Upper row (yellow wires)
       +12V  +12V  +12V  +12V
       [  ]  [  ]  [  ]  [  ]

       [  ]  [  ]  [  ]  [  ]
        GND   GND   GND   GND
      Lower row (black wires)
```

This is the **builder-reported wiring of the final modified adapter shown in the [final-adapter photos](#final-modified-tesla-v100-adapter-used-in-this-build)**, not a universal PCIe/EPS connector diagram. In the modified single-branch adapter, three incoming yellow +12 V conductors feed four GPU-side +12 V contacts (one incoming conductor is shared between two contacts); the four black ground conductors supply the four GND contacts. The server-side 35 cm extension remains unmodified.

**Wire-color convention:** in common ATX power cables yellow generally denotes +12 V and black denotes ground. This convention **does not independently verify** the electrical polarity or contact mapping of a third-party or rewired adapter. The diagram above is an orientation-specific account of this installation; a connector viewed from the wire-entry side, or rotated, appears different.


> **Safety:** The physical wire arrangement and operational tests do not replace verification of polarity, pin assignments, and cable current capacity. Do not connect a lookalike cable without confirming its actual wiring.

<!-- TODO: document verified contact numbering if needed -->

## BIOS and firmware notes

<!-- TODO: UEFI settings used (Above 4G decoding / MMIO, PCIe slot settings, power profile), IMM2 and UEFI firmware versions -->

- Windows: install the NVIDIA **data-center driver** (560.81 here). The cards run in **TCC** mode, so they are compute-only with no display.
- CUDA 12.x is the last series that supports Volta (CC 7.0). CUDA 13 does not.
