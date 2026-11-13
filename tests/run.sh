#!/usr/bin/env bash
# Headless integration tests. Each tests/test_*.lua runs in a fresh Neovim against freshly built
# fixture repos in a temp dir.
#
#   tests/run.sh            run everything
#   tests/run.sh branches   run tests whose name contains "branches"
#
# Env: GG_TEST_TIMEOUT (seconds per test file, default 90), GG_KEEP=1 to keep the temp dir.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gitgraph-tests.XXXXXX")
if [[ -z "${GG_KEEP:-}" ]]; then
  trap 'rm -rf "$WORK"' EXIT
else
  echo "keeping $WORK"
fi
TIMEOUT=${GG_TEST_TIMEOUT:-90}
export GG_TIMEOUT=$TIMEOUT

# Isolate git from the user's config (signing, hooks, default branch, ...), for fixture setup and for
# the git commands the plugin runs inside Neovim.
cat > "$WORK/gitconfig" <<CFG
[user]
  name = Test
  email = test@example.com
[init]
  defaultBranch = main
[advice]
  detachedHead = false
CFG
export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_NOSYSTEM=1

# shellcheck source=tests/fixtures.sh
source "$ROOT/tests/fixtures.sh"

failed=0
for spec in "$ROOT"/tests/test_*.lua; do
  name=$(basename "$spec" .lua)
  name=${name#test_}
  [[ -n "${1:-}" && "$name" != *"$1"* ]] && continue

  dir="$WORK/$name"
  mkdir -p "$dir"
  if ! setup_fixtures "$dir" >"$dir/fixtures.log" 2>&1; then
    echo "✗ $name: fixture setup failed (see $dir/fixtures.log)"
    failed=1
    continue
  fi

  out="$dir/results.txt"
  # perl kills nvim on timeout and exits 142 (macOS has no `timeout`)
  GG_ROOT=$ROOT FIXTURES=$dir GG_OUT=$out perl -e '
    my $pid = fork // die; if (!$pid) { exec @ARGV or die }
    $SIG{ALRM} = sub { kill "KILL", $pid; exit 142 };
    alarm $ENV{GG_TIMEOUT}; waitpid $pid, 0; exit($? >> 8)' \
    nvim --headless --clean -c "luafile $spec" >"$dir/nvim.log" 2>&1 </dev/null
  code=$?

  passed=$(grep -c '^PASS' "$out" 2>/dev/null)
  passed=${passed:-0}
  problems=$(grep -E '^(FAIL|ERROR)' "$out" 2>/dev/null)
  if [[ $code -ne 0 ]]; then
    echo "✗ $name: nvim exited with $code (142 = timed out after ${TIMEOUT}s), $passed passed before that"
    tail -5 "$dir/nvim.log" | sed 's/^/    /'
    failed=1
  elif [[ -n "$problems" ]]; then
    echo "✗ $name: $passed passed"
    echo "$problems" | sed 's/^/    /'
    failed=1
  elif [[ "$passed" -eq 0 ]]; then
    echo "✗ $name: no results"
    failed=1
  else
    echo "✓ $name: $passed passed"
  fi
done

exit $failed
