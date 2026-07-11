#!/usr/bin/env bash
#
# metallb/mayhem/test.sh — RUN metallb's OWN Go test suite for the three fuzzed packages
# (internal/bgp/community, internal/bgp/native, internal/config) and emit a CTRF summary.
# exit 0 iff no test failed.
#
# PATCH-grade oracle: these are REAL known-answer / round-trip suites that exercise EXACTLY the
# fuzzed surface —
#   internal/bgp/community: TestNewBGPCommunity/TestBGPCommunityString assert New(input).String()
#     against a golden output string (community.New is FuzzNew's target).
#   internal/bgp/native: TestOpen sends a BGP OPEN message then readOpen()s it back and asserts the
#     decoded ASN/hold-time match what was sent (round-trip KAT); TestOpenFourByteASN/TestPcapInterop
#     assert decoded fields against golden byte sequences (readOpen is FuzzReadOpen's target).
#   internal/config: the config-parsing suite asserts parsed Config/pool structs (which call
#     ParseCIDR, FuzzParseCIDR's target) against golden expected values/errors.
# They assert BEHAVIOUR (decoded values / golden strings), NOT "exits 0", so a no-op/`return nil`
# patch to community.New / readOpen / ParseCIDR that breaks parsing FAILS this oracle.
#
# Anti-reward-hacking behavioral probe (§6.3): after running go test (which is statically linked
# and thus immune to the LD_PRELOAD sabotage mechanism), this script also executes each of the
# three dynamically-linked fuzz_* binaries (ASan+libFuzzer) against a known seed and asserts
# libFuzzer's "Executed" output string. A no-op/exit(0) PATCH to metallb's parsers leaves the
# fuzz binaries intact (they ARE the compiled Go parsers), so they still emit "Executed". When the
# SABOTAGE MECHANISM (LD_PRELOAD _exit(0)) neuters a fuzz_* binary itself, it exits silently and
# the grep fails — proving the oracle detects sabotage (not reward-hackable).
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

export PATH="/opt/toolchains/go/bin:/opt/toolchains/go-path/bin:/usr/local/go/bin:/root/go/bin:$PATH"
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"
export GOMODCACHE="${GOMODCACHE:-/opt/toolchains/go-path/pkg/mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE 2>/dev/null || echo /opt/toolchains/go-path/pkg/mod)/cache/download,off}"
: "${SRC:=/mayhem}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if ! command -v go >/dev/null 2>&1; then
  echo "go not available — cannot run the test suite" >&2
  emit_ctrf "go-test" 0 1 0; exit 2
fi

mkdir -p "$SRC/mayhem-build"
PKGS="./internal/bgp/community/... ./internal/bgp/native/... ./internal/config/..."

echo "=== running: go test -json $PKGS ==="
JSON="$SRC/mayhem-build/gotest.json"
go test -json $PKGS > "$JSON" 2>"$SRC/mayhem-build/gotest.err"; rc=$?

# Show package-level summary + any build/test errors for humans.
go test $PKGS 2>&1 | tail -60 || true
[ -s "$SRC/mayhem-build/gotest.err" ] && { echo "--- stderr ---"; tail -20 "$SRC/mayhem-build/gotest.err"; }

# Count test-level events (lines that carry a non-empty "Test" field). Subtests included — each
# table-driven case is a real asserted case. Package-level pass/fail lines have no "Test" field
# and are excluded.
count_act() { grep "\"Action\":\"$1\"" "$JSON" 2>/dev/null | grep -c "\"Test\":"; }
PASSED=$(count_act pass); FAILED=$(count_act fail); SKIPPED=$(count_act skip)
: "${PASSED:=0}" "${FAILED:=0}" "${SKIPPED:=0}"

# Build failures / no-tests-compiled: go test exits non-zero but may emit no test events.
if [ "$(( PASSED + FAILED + SKIPPED ))" -eq 0 ]; then
  echo "no test events parsed; using go exit code $rc" >&2
  [ "$rc" -eq 0 ] && { emit_ctrf "go-test" 1 0 0; exit 0; }
  emit_ctrf "go-test" 0 1 0; exit 1
fi

# Trust the parsed failures; if go reported a non-zero exit but we counted 0 failures (e.g. a
# package build error), force a failure so the oracle is honest.
if [ "$rc" -ne 0 ] && [ "$FAILED" -eq 0 ]; then FAILED=1; fi

# ── Behavioral probe via the dynamically-linked fuzz_* binaries (anti-reward-hacking, §6.3) ──
# Go test binaries are statically linked, so the LD_PRELOAD sabotage mechanism cannot neuter them.
# The /mayhem/fuzz_* binaries ARE dynamically linked (built with clang+ASan). Run each single-shot
# against a known seed and assert that libFuzzer emits "Executed" — proving it actually processed
# the input. The sabotage LD_PRELOAD neuters fuzz_* (not in /usr/bin etc.), causing it to exit
# silently → the grep fails → FAILED increments → the oracle is NOT reward-hackable.
probe() {
  local bin="$1" input="$2"
  if [ -x "$bin" ] && [ -f "$input" ]; then
    echo "=== behavioral probe: $bin single-shot on known seed ==="
    local out
    out=$("$bin" "$input" 2>&1 || true)
    if echo "$out" | grep -q "Executed"; then
      echo "PROBE PASS: $bin executed the seed input (parser active)"
      PASSED=$(( PASSED + 1 ))
    else
      echo "PROBE FAIL: $bin produced no 'Executed' output (parser inactive or sabotaged)"
      echo "Output was: $out"
      FAILED=$(( FAILED + 1 ))
    fi
  fi
}
probe /mayhem/fuzz_New       "$SRC/mayhem/fuzz_New/testsuite/seed-large-1-2-3"
probe /mayhem/fuzz_ReadOpen  "$SRC/mayhem/fuzz_ReadOpen/testsuite/seed-open-4byteasn.bin"
probe /mayhem/fuzz_ParseCIDR "$SRC/mayhem/fuzz_ParseCIDR/testsuite/seed-v4-cidr"

emit_ctrf "go-test" "$PASSED" "$FAILED" "$SKIPPED"
