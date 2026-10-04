# Antumbra developer entry points. See docs/building.md.
SHELL := /bin/bash
.PHONY: lint test check-packages build minimal clean

lint:            ## static checks: shell, python, nftables, tor, systemd units, yaml
	tests/lint.sh

test: lint       ## lint plus unit tests
	python3 -m pytest -q tests/unit

check-packages:  ## every package name exists in Debian trixie arm64
	tests/check-packages.sh

build:           ## full build (needs root for rootfs/squashfs)
	build/build.sh

minimal:         ## pipeline validation build without Phosh, apps or Tor Browser
	ANTUMBRA_MINIMAL=1 build/build.sh

clean:
	rm -rf build/out build/work
