#!/usr/bin/env bash
# Exercise the exact GLIBC-gate shell body embedded in release-linux.yml.
# Intended to run in a Linux container with Ruby and coreutils installed.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/daemon/target/x86_64-unknown-linux-gnu/release" "$WORK/bin"
# Both binaries the release ships — the gate walks them, and a fixture with
# only the daemon would let a regression that skips the CLI pass.
touch "$WORK/daemon/target/x86_64-unknown-linux-gnu/release/term-meshd" \
  "$WORK/daemon/target/x86_64-unknown-linux-gnu/release/tm-agent"

# shellcheck disable=SC2016 # Keep the GitHub expression literal for Ruby.
ruby -ryaml -e '
  workflow = YAML.load_file(ARGV.fetch(0))
  step = workflow.fetch("jobs").fetch("build").fetch("steps")
    .find { |candidate| candidate["name"] == "verify glibc floor" }
  abort "verify glibc floor step not found" unless step
  puts step.fetch("run").gsub("${{ matrix.rust_target }}", "x86_64-unknown-linux-gnu")
' "$ROOT/.github/workflows/release-linux.yml" > "$WORK/gate.sh"

cat > "$WORK/bin/objdump" <<'EOF'
#!/usr/bin/env bash
case "${GATE_MODE:?}" in
  objdump_fail) exit 42 ;;
  above) printf '%s\n' '000000 GLIBC_2.18 symbol' ;;
  ok|sort_fail) printf '%s\n' '000000 GLIBC_2.17 symbol' ;;
  *) exit 99 ;;
esac
EOF
cat > "$WORK/bin/sort" <<'EOF'
#!/usr/bin/env bash
[[ "${GATE_MODE:?}" != sort_fail ]] || exit 43
exec /usr/bin/sort "$@"
EOF
chmod +x "$WORK/bin/objdump" "$WORK/bin/sort"

run_case() {
  local mode=$1 expected=$2 actual
  set +e
  (cd "$WORK/daemon" && PATH="$WORK/bin:$PATH" GATE_MODE="$mode" bash "$WORK/gate.sh")
  actual=$?
  set -e
  [[ "$actual" == "$expected" ]] \
    || { echo "$mode: expected exit $expected, got $actual" >&2; exit 1; }
  echo "$mode: exit $actual"
}

run_case objdump_fail 42
run_case sort_fail 43
run_case above 1
run_case ok 0
echo 'GLIBC gate simulations passed'
