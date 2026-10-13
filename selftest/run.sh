#!/bin/sh
# go-toolchain pack selftest. Exercises the pack's own scripts against a throwaway
# project, with a recording `go` shim first on PATH so the checks pin the exact argv
# the pack hands the toolchain and need no Go module, network or build cache.
#
# Checks:
#   1. timeout: both `go test` engine commands in pack.yml (go-test, go-coverage)
#      carry an explicit -timeout, and carry the SAME value (the single-run
#      convention reuses one run's profile for both, so the two must agree);
#   2. timeout: the coverage producer's own fallback `go test` run (no fresh stamp)
#      passes that same -timeout, so a slow package is not killed at Go's 10m default;
#   3. exclusions: through the producer + sandboxed convert, a justified .go path
#      present in the profile is excluded with its reason; a justified .go path absent
#      from every inventory gets one synthetic excluded record (measured: false); a
#      justified NON-.go path (a .ts line in a mixed repository's shared exclusions
#      file) yields NO record, since another toolchain pack answers for it; a line
#      with no justification is dropped and its path stays measured.
#
# Usage: sh selftest/run.sh        Exit 0 = every check passed. POSIX sh.

set -u

pack_dir=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/go-toolchain-selftest.XXXXXX")
trap 'rm -rf "$work"' EXIT INT TERM

failures=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

# --- the recording go shim -------------------------------------------------------
shim_dir="$work/bin"
mkdir -p "$shim_dir"
cat > "$shim_dir/go" <<'SHIM'
#!/bin/sh
# Records every invocation, then fakes just enough of the toolchain for the
# producer: `go test -coverprofile=<f>` writes a fixed profile, `go list -m`
# prints the module, `go list -f ...` prints the package's .go files.
echo "$*" >> "$GO_SHIM_LOG"
case "$1" in
  test)
    for a in "$@"; do
      case "$a" in
        -coverprofile=*)
          {
            echo "mode: set"
            echo "example.com/demo/pkg/a/a.go:3.20,5.2 2 1"
            echo "example.com/demo/pkg/b/b.go:3.20,5.2 3 0"
          } > "${a#-coverprofile=}"
          ;;
      esac
    done
    exit 0
    ;;
  list)
    if [ "${2:-}" = "-m" ]; then
      echo "example.com/demo"
    else
      echo "example.com/demo/pkg/a/a.go"
      echo "example.com/demo/pkg/b/b.go"
    fi
    exit 0
    ;;
esac
exit 0
SHIM
chmod +x "$shim_dir/go"

# --- 1. pack.yml engine commands carry one explicit -timeout ---------------------
engine_command() {
  awk -v want="  $1:" '
    $0 == want { inside = 1; next }
    inside && /^  [^ ]/ { exit }
    inside && /^    command:/ { sub(/^    command: */, ""); print; exit }
  ' "$pack_dir/pack.yml"
}
timeout_of() {
  for word in $1; do
    case "$word" in -timeout=*) echo "${word#-timeout=}"; return ;; esac
  done
}
test_cmd=$(engine_command go-test)
coverage_cmd=$(engine_command go-coverage)
test_timeout=$(timeout_of "$test_cmd")
coverage_timeout=$(timeout_of "$coverage_cmd")
if [ -n "$test_timeout" ]; then
  pass "timeout: go-test command carries -timeout=$test_timeout ($test_cmd)"
else
  fail "timeout: go-test command has no -timeout, so Go's 10m default applies (got: $test_cmd)"
fi
if [ -n "$coverage_timeout" ]; then
  pass "timeout: go-coverage command carries -timeout=$coverage_timeout ($coverage_cmd)"
else
  fail "timeout: go-coverage command has no -timeout, so Go's 10m default applies (got: $coverage_cmd)"
fi
if [ -n "$test_timeout" ] && [ "$test_timeout" = "$coverage_timeout" ]; then
  pass "timeout: go-test and go-coverage agree on -timeout=$test_timeout"
else
  fail "timeout: go-test (-timeout=${test_timeout:-none}) and go-coverage (-timeout=${coverage_timeout:-none}) must agree"
fi

# --- project fixture with a shared, mixed-language exclusions file ---------------
proj="$work/project"
mkdir -p "$proj/.backstop"
tab=$(printf '\t')
{
  echo "# shared by every toolchain pack in this repository"
  echo ""
  echo "pkg/a/a.go${tab}generated bindings, exercised only by the integration rig"
  echo "pkg/gone/gone.go${tab}declared but absent from every inventory"
  echo "web/src/workflow.ts${tab}runs in a workflow sandbox; another pack answers for it"
  echo "pkg/b/b.go"
} > "$proj/.backstop/coverage-exclusions"

# --- 2. the producer's fallback run carries the same -timeout --------------------
log="$work/go.log"
: > "$log"
(cd "$proj" && GO_SHIM_LOG="$log" PATH="$shim_dir:$PATH" sh "$pack_dir/scripts/coverage-produce.sh") 2> "$work/produce.err"
producer_test=$(grep '^test ' "$log" | head -1)
producer_timeout=$(timeout_of "$producer_test")
if [ -n "$producer_timeout" ] && [ "$producer_timeout" = "$coverage_timeout" ]; then
  pass "timeout: producer fallback runs go $producer_test"
else
  fail "timeout: producer fallback must pass -timeout=${coverage_timeout:-<engine value>} (got: go ${producer_test:-<no test run>})"
fi

# --- 3. exclusions through producer + convert ------------------------------------
sh "$pack_dir/scripts/coverage-to-records.sh" < "$proj/cover.out" > "$work/records.json" 2>/dev/null
convert_status=$?
# Guard the negative check below: a convert that crashes emits no records at all,
# which would make "no record for the .ts path" pass for the wrong reason.
if [ "$convert_status" -eq 0 ] && [ "$(head -c 1 "$work/records.json")" = "[" ]; then
  pass "exclusions: convert exited 0 and emitted a records array"
else
  fail "exclusions: convert exited $convert_status / emitted no records array"
fi
# Records are flat JSON objects (no nested braces), so one grep isolates each.
rec() { grep -o "{\"path\":\"$1\"[^}]*}" "$work/records.json"; }
count() { grep -o "{\"path\":\"$1\"" "$work/records.json" | wc -l | tr -d ' '; }

r=$(rec pkg/a/a.go)
case "$r" in
  *'"measured":true,"excluded":true,'*'"justification":"generated bindings, exercised only by the integration rig"'*)
    pass "exclusions: justified profiled .go path is excluded with its reason ($r)" ;;
  *) fail "exclusions: justified profiled .go path needs excluded:true + reason (got: ${r:-none})" ;;
esac
r=$(rec pkg/gone/gone.go)
case "$r" in
  *'"covered":0,"total":0,"measured":false,"excluded":true,'*'"justification":"declared but absent from every inventory"'*)
    pass "exclusions: absent declared .go path gets one synthetic excluded record ($r)" ;;
  *) fail "exclusions: absent declared .go path needs a synthetic excluded record (got: ${r:-none})" ;;
esac
n=$(count web/src/workflow.ts)
if [ "$n" -eq 0 ]; then
  pass "exclusions: declared non-.go path (.ts) yields no record"
else
  fail "exclusions: declared .ts path must yield no go-toolchain record (got $n: $(rec web/src/workflow.ts))"
fi
r=$(rec pkg/b/b.go)
case "$r" in
  *'"covered":0,"total":3,"measured":true,"excluded":false,'*)
    case "$r" in
      *justification*) fail "exclusions: unjustified path must carry no justification (got: $r)" ;;
      *) pass "exclusions: unjustified line is dropped; path stays measured ($r)" ;;
    esac ;;
  *) fail "exclusions: unjustified path must stay a measured 0/3 record (got: ${r:-none})" ;;
esac
dropped=$(grep -c 'dropping malformed coverage exclusion' "$work/produce.err")
if [ "$dropped" -eq 1 ]; then
  pass "exclusions: producer reported 1 dropped declaration"
else
  fail "exclusions: producer reported $dropped dropped declarations, want 1"
fi

if [ "$failures" -ne 0 ]; then
  echo "selftest: $failures check(s) failed"
  exit 1
fi
echo "selftest: all checks passed"
