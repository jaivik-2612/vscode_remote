# VM test-run page

The scripts that built the "Antumbra QEMU Test Run" page from the VM runs
of October 2026: one self-contained HTML file with the screenshots
embedded as data URIs, the checks of each run grouped by phase, the boot
timeline and how to run the image yourself. They read the outputs of
`tests/vm/antumbra_vm.py` and never change them. Python's standard library
only; the page loads its fonts from Google Fonts.

| Script | What it builds |
|---|---|
| `make_report.py` | the page for one smoke-test run: verdict, checks by phase, boot timeline from the serial log, the shutdown back into the initramfs, and the "What the first VM runs found" table of `docs/vm-testing.md` |
| `make_report2.py` | the page for several runs on one image, from a JSON spec: a tally per run, screenshots, what the round added, each run's checks, the pop-up motor's sleep test (`tests/kernel/genpd-sleep-vm.sh`), what review and the VM found, caveats, how to run it |
| `spec3.py` | the spec of the last page built (runs f1 to f4 of 6 Oct 2026); the template for the next one |

## One run

```sh
make vm-test                                   # or tests/vm/antumbra_vm.py with a run directory
tests/vm/report/make_report.py RUN_DIR /tmp/report.html \
    --shot RUN_DIR/smoke/display.png "The Welcome screen" \
    --shot RUN_DIR/smoke/tour-apps.png "The app grid" \
    --commit "$(git rev-parse --short HEAD)" --host "QEMU TCG on an x86-64 host"
```

`RUN_DIR` holds `serial.log` and `smoke/report.json` (`make vm-test` uses
`build/work/qemu-virt/vm-run`); `--bundle NAME SIZE
SHA256` adds the test bundle's details, `--packages N` the package count,
`--doc FILE` another source for the defects table.

## Several runs

```sh
make vm-start                                  # a debug VM for the motor's sleep test
tests/kernel/genpd-sleep-vm.sh > /tmp/genpd-sleep.log 2>&1
tests/vm/report/spec3.py --notes notes.json -o /tmp/spec.json \
    "$(git rev-parse --short HEAD)" bundle.json 198 /tmp/genpd-sleep.log
tests/vm/report/make_report2.py /tmp/spec.json /tmp/report.html
```

`spec3.py` reads each run's `smoke/report.json` and screenshots from
`build/work/qemu-virt/run-<id>/` (`--work` names another directory).
`bundle.json` describes a split test bundle (`name`, `size`, `parts`,
`prefix`, `sha256`, `dir`), or `-` leaves the download steps out; the third
argument is the unit-test count shown in the tally. `notes.json` maps a run
id to a note shown with that run, and its `_android_run` names the Android
run shown (default `f4`). For a new page, copy `spec3.py` and change the
runs, the texts, the findings and the screenshots: the texts describe the
image of 6 Oct 2026 and go stale with it.

Fed the same runs, these scripts rebuild the published page byte for byte,
except one sentence of its camera section that was reworded for the
repository.

The daily VM run in the plan (`docs/plan/queue.md`, T1 to T3) builds its
own page; these scripts are the record of how the October pages were made
and a starting point for a weekly summary.
