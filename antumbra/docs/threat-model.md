# Threat model

Antumbra inherits Tails' threat model and adds what a phone changes. The
honest summary: it protects the content and destination of your
communications and leaves no trace on the device, as long as the device is
in your physical control and its hardware and firmware are not already
compromised.

## Assets

- Who you talk to and what you say or read online.
- The fact that you use Tor at all (weaker: see *Censorship* below).
- The phone's identifiers: Wi-Fi MAC address, hostname, IMEI and IMSI.
- Everything that was in the session: files, keys, history, passwords.
- The contents of Persistent Storage.

## Adversaries and what they get

| Adversary | Attack | Antumbra's answer | Status |
|---|---|---|---|
| Local network observer, Wi-Fi operator, ISP | sees destinations and content | the firewall allows only Tor to leave the device; DNS goes to Tor; IPv6 is dropped | shipped |
| Same | links sessions by MAC address | `macchanger` on every interface at session start (on this port the firmware address is random anyway); random MAC in scans; no hostname or client identifier in DHCP | shipped; MAC survival across suspend to be validated |
| Same | finds hidden networks the phone probes for | hidden-network profiles are refused | shipped |
| Mobile network operator, IMSI catcher | tracks the phone by IMSI/IMEI, locates it by cell | the modem radio is pinned to low-power mode (no IMSI attach, RF off); no ModemManager; the control channel is capability-gated so no app can turn the radio on | shipped; behaviour of this firmware in low-power mode without a SIM is unmeasured |
| Application exploit (browser) | reads files, reaches the network directly, uses the camera | Tor Browser runs in its own network namespace reaching only Tor; the firewall rejects everything else; no camera access without the portal prompt | partly: no AppArmor profile for the browser yet |
| Application exploit | escalates to root | no setuid helpers beyond sudo; sudo only for the Tor Browser launcher (argument-filtered) and, if enabled, the user's own passphrase; QRTR, ptrace, BPF, kexec and debugfs restricted | shipped |
| Malware in the session | persists across reboots | read-only verity-covered root, RAM overlay, no writable flash except the unlocked Persistent Storage | shipped |
| Someone who takes the powered-off phone | reads what was in RAM or on flash | memory zeroed on free and flushed at shutdown; nothing on flash except the LUKS2 volume (argon2id) | shipped; LPDDR4X remanence unmeasured |
| Someone who takes the locked, running phone | waits for a vulnerability, keeps it alive | screen lock with passphrase; auto-shutdown after 18 h locked, also from suspend | shipped; RTC alarm wake-up to be validated |
| Someone who takes the running phone and forces a reset | reboots into a memory-dumping image | not defended: an unlocked bootloader cannot verify what boots next, and a forced PMIC reset skips the orderly shutdown. Only a short lock-to-shutdown timer and shutting down before handing the phone over help | residual risk, documented |
| Evil maid with brief access | replaces the OS or boot image | not defended (no verified boot on an unlocked bootloader). The verity root hash in the boot image detects tampering with the root filesystem alone; a labelled USB medium cannot hijack the boot because the live partition is found by UUID on the internal storage and USB devices are not authorised in the initramfs | partial |
| Censor | blocks Tor | obfs4, snowflake, webtunnel and meek bridges through Tor Browser's transports; bridge lines entered at the Welcome screen | shipped; no QR-code or Moat flow yet |
| Global passive adversary | correlates traffic entering and leaving Tor | out of scope, as for Tails |
| Hardware or firmware backdoor (baseband, TrustZone, GPU firmware) | anything | out of scope. The modem shares the SoC; its isolation from application memory on SM8150 is not documented publicly |
| You | reveal who you are inside Tor | out of scope; Tails' warnings apply |

## What Antumbra does not do

- It does not make the phone a phone: no calls, SMS or mobile data.
- It does not verify its own boot chain.
- It does not hide that a device is running Tor from the local network
  unless bridges are used.
- It does not protect against an adversary who had the phone before you
  flashed it.
- It does not protect against microphone or camera use by an application
  you granted access to; the phone has no kill switch.
- It has not been reviewed by Tails, Tor Project or anyone else, and has
  not run on hardware.

## Assumptions

- You flash your own build or a release whose signature you verified.
- You keep the phone in your physical control and shut it down, rather
  than suspend it, when that matters.
- The firmware you provide for your own device is the firmware OnePlus
  shipped for it.
