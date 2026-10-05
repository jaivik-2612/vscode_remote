# Kernel test modules

Out-of-tree modules that check kernel behaviour Antumbra's patches rely on.
They are built against the qemu-virt kernel and loaded only in the VM;
nothing here goes into an image. Kernel modules must be GPL-2.0-compatible
to use the kernel's GPL-only symbols, so these sources are GPL-2.0-only.

## genpd-sleep: the pop-up motor's system-sleep gate

`genpd-sleep/genpd_sleep_test.c` registers a generic PM domain with logging
`power_on`/`power_off` callbacks and one platform device as its consumer,
the same shape as the pop-up camera motor (the domain) and the IMX471 front
sensor (the consumer). It mirrors the gate that
`device/oneplus-hotdog/kernel/patches/0102-media-qcom-hotdog-popup-pm-shutdown-safety.patch`
adds to `hotdog-popup-motor.c`:

- at `PM_SUSPEND_PREPARE` a raised camera is retracted and a `sleeping` flag
  is set;
- while it is set, the domain callbacks only record the state genpd asks for;
- at `PM_POST_SUSPEND` the flag is cleared and a work item raises the camera
  again if the domain is on and its consumer was active when genpd powered it
  back on.

The fake camera is a flag: an ungated `power_on` raises it, an ungated
`power_off` or the retract lowers it. A suspend-to-idle cycle woken by the
RTC then shows what genpd does and what the gate changes. Module parameters:

| Parameter | Meaning |
|---|---|
| `gate` (in) | mirror the patch's gate; `gate=0` behaves like the unpatched driver |
| `active` (in) | keep the consumer runtime-active across sleep, like a stream |
| `noirq_power_on`, `noirq_power_off` | callbacks genpd made in the noirq phases |
| `noirq_moves` | of those, how many would have driven the motor |
| `gated_calls` | callbacks that only recorded state |
| `prepare_retracts` | retracts at `PM_SUSPEND_PREPARE` |
| `reconcile_raises` | raises by the post-resume work |
| `raised`, `domain_on` | fake camera position, domain state |

"noirq" means between the consumer's own `suspend_noirq` and `resume_noirq`:
genpd powers the domain off right after the first and on right before the
second.

Expected results:

| Case | Expected |
|---|---|
| `gate=1 active=0` | `noirq_power_on` >= 1 (genpd powers the off domain on in resume_noirq), `noirq_moves` = 0, `raised` = N, `reconcile_raises` = 0 |
| `gate=1 active=1` | `prepare_retracts` = 1, `noirq_power_off` >= 1, `noirq_moves` = 0, `reconcile_raises` = 1, `raised` = Y |
| `gate=0 active=0` | `noirq_moves` >= 1: the motion the patch prevents |

### Running it

With a debug VM image (`make vm-build`) running with its debug console
(`make vm-start`):

```sh
tests/kernel/genpd-sleep-vm.sh
```

The script builds the module against `build/work/qemu-virt/kernel-build`
(the sources in `build/cache/kernel` must still be the ones that build used),
copies it into the VM through the hvc0 root console, runs the three cases
with `rtcwake -m freeze` (or the RTC's `wakealarm` and `/sys/power/state`),
prints PASS or FAIL for each expectation and exits non-zero on a failure.
`--ko FILE` uses a module built elsewhere; `--sleep N` changes the
suspend length (default 5 s). The wake-up comes from the virt machine's
PL031 RTC alarm; if a cycle never returns (the console command times out
after 300 s), that wake-up path is what failed, not the gate.

To build by hand:

```sh
make -C build/cache/kernel O="$PWD/build/work/qemu-virt/kernel-build" \
    ARCH=arm64 LLVM=1 LOCALVERSION=-antumbra-virt \
    M="$PWD/tests/kernel/genpd-sleep" MO=/tmp/genpd-sleep modules
```

`MO=` keeps the objects out of the source tree. The module's vermagic must
match the VM kernel's release (`6.17.0-sm8150-hotdog-clean-antumbra-virt`).

What this does not test: the motor itself, its Hall sensors and the real
I2C failure in the noirq phases. Those, and the shutdown and probe paths of
the patch, are checked on the phone (docs/hardware-validation.md).
