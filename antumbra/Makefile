# Antumbra developer entry points. See docs/building.md.
SHELL := /bin/bash
.PHONY: lint test check-packages build minimal clean vm-build vm-run vm-start vm-console vm-stop vm-test vm-bundle

lint:            ## static checks: shell, python, nftables, tor, systemd units, yaml
	tests/lint.sh

test: lint       ## lint, unit tests and the headless Welcome UI self-test
	python3 -m pytest -q tests/unit
	tests/ui-selftest.sh

check-packages:  ## every package name exists in Debian trixie arm64
	tests/check-packages.sh

build:           ## full build (needs root for rootfs/squashfs)
	build/build.sh

minimal:         ## pipeline validation build without Phosh, apps or Tor Browser
	ANTUMBRA_MINIMAL=1 build/build.sh

clean:
	rm -rf build/out build/work

# --- QEMU test target (docs/vm-testing.md) ---------------------------------
VM_ENV = ANTUMBRA_DEVICE=qemu-virt ANTUMBRA_DEBUG=1
vm-build:        ## build the qemu-virt profile (debug build: root shell on the VM console)
	$(VM_ENV) build/build.sh
vm-run:          ## boot it in QEMU on this terminal (Ctrl-A X quits)
	$(VM_ENV) build/vm.sh run --debug
vm-start:        ## boot it in the background (vm-console, vm-shell, vm-stop)
	$(VM_ENV) build/vm.sh start --debug
vm-console:      ## attach to the running VM's serial console
	$(VM_ENV) build/vm.sh console
vm-stop:         ## stop the background VM
	$(VM_ENV) build/vm.sh stop
vm-test:         ## boot in the background and run the smoke test
	$(VM_ENV) tests/vm-smoke.sh --through-welcome --timeout-scale $(or $(SCALE),1)
vm-bundle:       ## package the qemu-virt build as a self-contained test bundle (.tar)
	$(VM_ENV) build/vm-bundle.sh
