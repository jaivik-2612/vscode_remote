# Kernel test modules

Out-of-tree modules that check kernel behaviour Antumbra's patches rely on.
They are built against the qemu-virt kernel and loaded only in the VM;
nothing here goes into an image. Kernel modules must be GPL-2.0-compatible
to use the kernel's GPL-only symbols, so these sources are GPL-2.0-only.

## genpd-sleep: genpd's noirq calls against a model of the motor's sleep gate

`genpd-sleep/genpd_sleep_test.c` registers a generic PM domain with logging
`power_on`/`power_off` callbacks and one platform device as its consumer,
the same shape as the pop-up camera motor (the domain) and the IMX471 front
sensor (the consumer). Its callbacks, PM notifier and work item are a model
of the gate that
`device/oneplus-hotdog/kernel/patches/0102-media-qcom-hotdog-popup-pm-shutdown-safety.patch`
adds to `hotdog-popup-motor.c`: a copy of the driver's flag logic, kept in
step with it by hand. The driver itself is not built or loaded.

- at `PM_SUSPEND_PREPARE` a raised camera is retracted and a `sleeping` flag
  is set; a retract that fails is marked for a retry;
- while the flag is set, the domain callbacks only record the state genpd
  asks for;
- the driver tracks whether a consumer holds the camera (`consumer_on`): a
  successful `power_on` sets it, every `power_off` clears it, and a gated
  `power_on` reads it from the consumers' runtime state;
- at `PM_POST_SUSPEND` the flag is cleared and a work item retries a failed
  retract when no consumer holds the camera, or raises the camera again when
  the domain is on and a consumer holds it.

The fake camera is a flag: an ungated `power_on` raises it; an ungated
`power_off`, the retract or the work item's retry lowers it. A
suspend-to-idle attempt woken by the RTC then shows what genpd does and what
the gate changes. Two more PM notifiers belong to the test, not the model:
one, registered after the gate's, refuses `PM_SUSPEND_PREPARE` when `veto=1`
(an aborted suspend: the PM core sends `PM_POST_SUSPEND` and never freezes);
the other, ahead of the gate's, flushes genpd's power-off work at
`PM_POST_SUSPEND`. `genpd_complete()` queues that work on `pm_wq`, which is
thawed before `PM_POST_SUSPEND` goes out, so it usually runs while the gate
is still closed; the flush makes that order certain.

Module parameters:

| Parameter | Meaning |
|---|---|
| `gate` (in) | model the patch's gate; `gate=0` behaves like the unpatched driver |
| `legacy` (in) | model the gate as 0102 first had it: reopen on `domain_on`, no retry of a failed retract |
| `active` (in) | keep the consumer runtime-active across sleep, like a stream |
| `fail_close` (in) | at load, raise the camera for the consumer, then fail its close once: camera raised, domain on, consumer suspended |
| `fail_retract` (in) | fail the `PM_SUSPEND_PREPARE` retract once |
| `veto` (in) | refuse `PM_SUSPEND_PREPARE` (an aborted suspend) |
| `noirq_power_on`, `noirq_power_off` | callbacks genpd made in the noirq phases |
| `noirq_moves` | of those, how many would have driven the motor |
| `gated_calls` | callbacks that only recorded state |
| `prepare_retracts` | retracts at `PM_SUSPEND_PREPARE` |
| `reconcile_runs` | runs of the post-resume work |
| `reconcile_raises`, `reconcile_retracts` | raises and retried retracts by the post-resume work |
| `failed_closes`, `failed_retracts`, `vetoes` | the injected failures that happened |
| `raised`, `domain_on`, `consumer_on` | fake camera position, domain state, consumer holding the camera |

"noirq" means between the consumer's own `suspend_noirq` and `resume_noirq`:
genpd powers the domain off right after the first and on right before the
second.

Expected results:

| Case | Expected |
|---|---|
| 1 `gate=1 active=0` | `noirq_power_on` >= 1 (genpd powers the off domain on in resume_noirq), `noirq_moves` = 0, `raised` = N, `reconcile_raises` = 0 |
| 2 `gate=1 active=1` | `prepare_retracts` = 1, `noirq_power_off` >= 1, `noirq_moves` = 0, `reconcile_raises` = 1, `raised` = Y |
| 3 `gate=0 active=0` | `noirq_moves` >= 1: the motion the patch prevents |
| 4 `gate=1 fail_close=1 veto=1` | the write to `/sys/power/state` fails, `vetoes` = 1, no noirq call, `prepare_retracts` = 1, `domain_on` = Y, `reconcile_runs` >= 1, `reconcile_raises` = 0, `raised` = N |
| 5 `gate=1 fail_close=1 fail_retract=1` | `failed_retracts` = 1, `noirq_power_off` >= 1, `noirq_moves` = 0, `reconcile_retracts` = 1, `reconcile_raises` = 0, `raised` = N |
| 6 case 4 with `legacy=1` | `reconcile_raises` = 1, `raised` = Y: the defect case 4 catches |
| 7 case 5 with `legacy=1` | `reconcile_retracts` = 0, `raised` = Y: the defect case 5 catches |

Cases 6 and 7 pass when the first version of the gate shows its defects;
they keep cases 4 and 5 honest.

### Running it

With a debug VM image (`make vm-build`) running with its debug console
(`make vm-start`):

```sh
tests/kernel/genpd-sleep-vm.sh
```

The script builds the module against `build/work/qemu-virt/kernel-build`
(the sources in `build/cache/kernel` must still be the ones that build used),
copies it into the VM through the hvc0 root console, runs the seven cases
with `rtcwake -m freeze` (or the RTC's `wakealarm` and `/sys/power/state`),
prints PASS or FAIL for each expectation and exits non-zero on a failure.
`--ko FILE` uses a module built elsewhere; `--sleep N` changes the
suspend length (default 5 s). The wake-up comes from the virt machine's
PL031 RTC alarm. The suspend runs from a detached job that prints a tag
ending in `-end`, with the result of its write to `/sys/power/state`, once
that write returns (at once for a refused suspend); the script looks for it
only in what `hvc0.log` gained during the case. If a cycle never returns
(no tag after 300 s), the wake-up path is what failed, not the gate.

To build by hand:

```sh
make -C build/cache/kernel O="$PWD/build/work/qemu-virt/kernel-build" \
    ARCH=arm64 LLVM=1 LOCALVERSION=-antumbra-virt \
    M="$PWD/tests/kernel/genpd-sleep" MO=/tmp/genpd-sleep modules
```

`MO=` keeps the objects out of the source tree. The module's vermagic must
match the VM kernel's release (`6.17.0-sm8150-hotdog-clean-antumbra-virt`).

## popup_gate_model.py: the same flags in userspace

`popup_gate_model.py` models the driver's sleep flags, as fixed and as 0102
first had them, inside a small model of genpd, and replays the failure
sequences of the review findings it fixed: a suspend aborted after a failed
close (the camera was raised with no stream), a retract or Hall read that
fails before sleep (the camera stayed raised), and a close of a camera
already seated (a settle push into the stop). It fails when the fixed logic
shows a defect or when the old logic no longer does. `tests/lint.sh` runs
it; it needs nothing but Python.

## What this does not test

The driver itself: `hotdog-popup-motor.c` is never built or loaded, so a
regression in its gate, its PM notifier or its reconcile passes here unless
the models are changed with it. Exercising it would need
`hotdog-popup-motor.ko` built for the VM with simulated GPIOs (`GPIO_SIM`),
a GPIO-driven PWM for STEP (`PWM_GPIO`) and a fake IIO provider for the two
Hall channels; that is not done. Nor are the motor, its Hall sensors and the
real I2C failure in the noirq phases, or the shutdown, probe, course-budget
and watchdog paths of the patch: those are checked on the phone
(docs/hardware-validation.md).
