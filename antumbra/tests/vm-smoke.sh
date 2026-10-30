#!/bin/sh
# Boot the qemu-virt build in QEMU and run the smoke test (docs/vm-testing.md).
# usage: tests/vm-smoke.sh [--timeout-scale F] [--no-stop] [-- VM.SH OPTIONS]
cd "$(dirname "$0")/.." || exit 1
exec python3 tests/vm/antumbra_vm.py smoke "$@"
