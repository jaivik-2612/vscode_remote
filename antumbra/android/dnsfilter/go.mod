module antumbra/dnsfilter

// x/net v0.60.0 needs Go 1.26 or later. build.sh builds the release
// binaries with exactly the toolchain below (GOTOOLCHAIN=go1.27.2).
go 1.26.0

toolchain go1.27.2

require golang.org/x/net v0.60.0
