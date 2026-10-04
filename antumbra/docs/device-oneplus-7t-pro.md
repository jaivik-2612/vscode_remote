# The OnePlus 7T Pro and its mainline port

| Item | Value |
|---|---|
| Codename | `hotdog` (the non-Pro 7T is `hotdogb`) |
| Variants | HD1913 (EU; the one the port validates), HD1911 (IN), HD1925 (T-Mobile McLaren). `fastboot getvar product` reports `msmnile` for all |
| SoC | Qualcomm SM8150-AC Snapdragon 855+, Adreno 640, 8 or 12 GB LPDDR4X, 256 GB UFS 3.0 |
| Display | 6.67" 1440x3120 AMOLED over DSI with DSC; stable at 60 Hz on mainline |
| Touch | Samsung S6SY761 |
| Wi-Fi / Bluetooth | Qualcomm WCN3990 (`ath10k_snoc`; Bluetooth via `hci_uart`/`btqca`) |
| Audio | WCD9340 codec, two TFA9874 amplifiers |
| Cameras | IMX586 (main), S5K3M5 (tele), IMX481 (wide), IMX471 (pop-up front) |
| Modem | SM8150 MPSS remote processor (QRTR/QMI); also hosts the Wi-Fi firmware |
| Sensors | SLPI sensor DSP (disabled by Antumbra) |
| NFC | NXP PN553 (disabled by Antumbra) |
| Fingerprint | Goodix optical, needs TrustZone services: never on mainline |

## The port Antumbra builds on

[hotdog-linux-bringup](https://github.com/Sr-0w/hotdog-linux-bringup)
by Robin Snyders, one developer, alpha quality, boots a close-to-mainline
Linux 6.17 directly from the stock OnePlus bootloader. Antumbra pins its
release tag `v0.2.0-alpha.2`: the kernel tree
`gitlab.com/sm8150-mainline/linux` at `v6.17.0-sm8150` plus 27 patches,
and the port's own DTBO and vbmeta images.

What the port reports (its status page, August 2026), and therefore what
Antumbra can expect:

| Subsystem | Port status | Notes |
|---|---|---|
| Boot from ABL, A/B slot marking | works | `fastboot boot` is refused; every test is a flash |
| UFS storage | works | inline encryption unused |
| Display | partial | 60 Hz fine; 90 Hz has DSI FIFO errors |
| Touch | partial | works when awake; resume lifecycle under validation |
| GPU (Freedreno, Turnip) | works | |
| Wi-Fi | partial | works incl. suspend; factory MAC handling, throughput and roaming remain. **Requires the modem processor** |
| Bluetooth | fixed on the 6.17 line | needs patches 0021-0023 (included); Antumbra keeps it off by default |
| Audio | partial | speakers and handset mic; no earpiece/headset |
| USB-C | partial | dual role, DisplayPort out, docks; charging at 900 mA depended on gadget enumeration |
| Cameras | partial | raw capture via libcamera |
| Modem | partial | boots, scans; no SIM-validated calls, SMS or data |
| GNSS | partial | engine starts and stops; no fixes |
| Sensors | partial | needs vendor SLPI firmware 2.2-00083 and an SSC build of iio-sensor-proxy; disabled in Antumbra |
| NFC | partial | reader mode; disabled in Antumbra |
| Suspend | partial | s2idle survives 30 cycles |
| Fingerprint | never | |

## Partitions Antumbra touches

| Partition | Size | Content |
|---|---|---|
| `boot_b` | 100663296 | Antumbra boot image |
| `dtbo_b` | 25165824 | the port's filtered DTBO |
| `vbmeta_b` | 65536 | the port's vbmeta with verification disabled (flags 3) |
| `userdata` | 232382812160 | nested 4096-byte-sector GPT: `ANTUMBRA_LIVE` (ext4, read-only, squashfs inside) and `ANTUMBRA_DATA` (LUKS2 Persistent Storage, created on first use) |

Untouched: `boot_a`, `dtbo_a`, `vbmeta_a`, both recoveries, Android's
`super`, `persist`, modem storage (`modemst1/2`, `fsg`, read-only through
`rmtfs -r`).

## Boot modes

- Fastboot: Power + Volume Up + Volume Down from power-off, or `adb reboot bootloader`.
- Recovery: Power + Volume Down.
- EDL (emergency download, for the MSM tool): Volume Up + Volume Down while connecting USB.
