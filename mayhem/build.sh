#!/usr/bin/env bash
#
# metallb/mayhem/build.sh — build metallb/metallb's OSS-Fuzz Go fuzz targets as sanitized
# libFuzzer binaries, REPLICATING OSS-Fuzz's compile_native_go_fuzzer.
#
# OSS-Fuzz target (projects/metallb/build.sh):
#   go get github.com/AdamKorcz/go-118-fuzz-build/testing
#   compile_native_go_fuzzer $(pwd)/internal/bgp/community   FuzzNew         fuzz_New
#   compile_native_go_fuzzer $(pwd)/internal/bgp/native      FuzzReadOpen    fuzz_ReadOpen
#   compile_native_go_fuzzer $(pwd)/internal/config          FuzzParseCIDR   fuzz_ParseCIDR
# i.e. three MODERN native harnesses (func FuzzX(f *testing.F), in the packages' own _test.go
# files) built with `go-118-fuzz-build -tags gofuzz -func <F> <pkgdir>` (the LEGACY/non-v2
# builder — compile_native_go_fuzzer's non-coverage path calls build_native_go_fuzzer_legacy,
# which invokes plain `go-118-fuzz-build`, NOT `go-118-fuzz-build_v2`), then linked with
# $LIB_FUZZING_ENGINE via clang++.
#   - fuzz_New:       internal/bgp/community.New(string) — BGP community string parser.
#   - fuzz_ReadOpen:  internal/bgp/native's BGP OPEN-message reader (readOpen, via bytes.Reader).
#   - fuzz_ParseCIDR: internal/config.ParseCIDR(string) — CIDR/range address-pool parser.
#
# We produce:
#   /mayhem/fuzz_New
#   /mayhem/fuzz_ReadOpen
#   /mayhem/fuzz_ParseCIDR
#
# DWARF gate (SPEC §6.2 item 10): Go's gc compiler always emits DWARF4 (no downgrade flag).
# The C shim clang links in front of the Go archive (LLVMFuzzerTestOneInput wrapper) defaults to
# DWARF5 with clang-19. We force that shim to DWARF3 via CGO_CFLAGS/CGO_CXXFLAGS and the final
# clang++ link to DWARF3 via $GO_DEBUG_FLAGS. verify-repo's `readelf -m1` check reads the FIRST
# CU (the C shim, at DWARF3) — satisfying the < 4 gate.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
# OSS-Fuzz Go path is ASAN-only (project.yaml sanitizers: [address]); UBSan is not part of the
# Go libFuzzer link. Keep ASan as the Go-fuzz sanitizer regardless of the base default. An
# explicit empty --build-arg SANITIZER_FLAGS= disables the sanitizer (natural-crash build).
: "${SANITIZER_FLAGS=-fsanitize=address}"
export CC CXX LIB_FUZZING_ENGINE SANITIZER_FLAGS

# Debug-info flags (SPEC §6.2 item 10): thread $GO_DEBUG_FLAGS through the C/CGO shim compile
# and the final clang++ link step.
: "${GO_DEBUG_FLAGS:=-g -gdwarf-3}"
export CGO_CFLAGS="${CGO_CFLAGS:+$CGO_CFLAGS }$GO_DEBUG_FLAGS"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:+$CGO_CXXFLAGS }$GO_DEBUG_FLAGS"

# Air-gapped contract (SPEC §6.5): the PATCH tier re-runs build.sh OFFLINE.
# $(go env GOMODCACHE) reads the pinned ENV under /opt/toolchains (set in the Dockerfile),
# so the file proxy path is correct regardless of $HOME.
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"

: "${SRC:=/mayhem}"
cd "$SRC"
go version

# go-118-fuzz-build's legacy builder needs the AdamKorcz testing shim as a module dep (its
# generated entrypoint imports it). Add it WITHOUT a trailing `go mod tidy` clobbering it —
# tidy first (resolves the real module graph), then `go get` the shim (order matters: tidy
# would otherwise prune the shim because nothing imports it until the builder generates code).
go mod tidy 2>&1 | tail -2 || true
go get github.com/AdamKorcz/go-118-fuzz-build/testing@latest 2>&1 | tail -2 || true

mkdir -p "$SRC/mayhem-build"

build_one() {
  local name="$1" func="$2" pkg="$3"
  echo "=== building $name ($pkg.$func, go-118-fuzz-build -tags gofuzz) ==="
  go-118-fuzz-build -tags gofuzz -o "$SRC/mayhem-build/$name.a" -func "$func" "$SRC/$pkg"
  # Link: DWARF3 via $GO_DEBUG_FLAGS ensures the C-shim CU (first in the binary) is at DWARF3.
  $CXX $SANITIZER_FLAGS $LIB_FUZZING_ENGINE $GO_DEBUG_FLAGS "$SRC/mayhem-build/$name.a" -o "/mayhem/$name"
  echo "built /mayhem/$name"
}

build_one fuzz_New       FuzzNew       internal/bgp/community
build_one fuzz_ReadOpen  FuzzReadOpen  internal/bgp/native
build_one fuzz_ParseCIDR FuzzParseCIDR internal/config

echo "build.sh complete:"
ls -la /mayhem/fuzz_New /mayhem/fuzz_ReadOpen /mayhem/fuzz_ParseCIDR 2>&1 || true
