#!/usr/bin/env bash
# Exercise the packaged helper with a stub xcrun in a scratch directory.
# Invoke with the helper path and an optional scenario name.
set -eu
helper=$1
scenario=${2:-all}
tmp=$(mktemp -d)
tmp=$(cd "$tmp" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
# A bare assertion that fails stops the script under set -e; name where.
trap 'echo "xcode-skills test: scenario $scenario failed at line $LINENO" >&2' ERR
export STUB=$tmp
cat >"$tmp/xcrun" <<'STUB'
#!/usr/bin/env bash
[ "$1 $2 $3 $4" = 'agent skills export --output-dir' ] || exit 2
case $(cat "$STUB/mode") in
  fail) exit 1 ;;
  empty) exit 0 ;;
  first) names='alpha beta gamma' ;;
  second) names='alpha gamma delta' ;;
esac
for name in $names; do mkdir -p "$5/$name"; printf 'fixture %s\n' "$name" > "$5/$name/SKILL.md"; done
echo 'Exported skills'
STUB
chmod +x "$tmp/xcrun"
echo first >"$tmp/mode"
run() { "$helper" --install --xcrun "$tmp/xcrun" --state "$tmp/state" --root "$tmp/r1" --root "$tmp/r2" >"$tmp/out" 2>"$tmp/err"; }
checklinks() {
  for root in r1 r2; do
    for n in "$@"; do
      entry=$tmp/$root/$n
      [ -L "$entry" ] || { echo "expected $entry to be a symlink" >&2; return 1; }
      [ "$(readlink "$entry")" = "$tmp/state/$n" ] || { echo "unexpected target for $entry" >&2; return 1; }
      [ -f "$entry/SKILL.md" ] && [ ! -L "$entry/SKILL.md" ] || { echo "expected $entry/SKILL.md to be a regular file" >&2; return 1; }
      [ "$(cat "$entry/SKILL.md")" = "fixture $n" ] || { echo "unexpected contents in $entry/SKILL.md" >&2; return 1; }
    done
  done
}
case "$scenario" in
all)
  for s in first update fail empty missing collision unrelated release root usage; do bash "$0" "$helper" "$s"; done
  exit
  ;;
first)
  run
  checklinks alpha beta gamma
  [ ! -s "$tmp/out" ]
  ;;
update)
  run
  echo second >"$tmp/mode"
  run
  checklinks alpha gamma delta
  [ ! -L "$tmp/r1/beta" ] && [ ! -L "$tmp/r2/beta" ] && [ ! -e "$tmp/state/beta" ] || exit 1
  ;;
fail | empty | missing)
  run
  cp -R "$tmp/state" "$tmp/snapshot"
  before=$(readlink "$tmp/r1/beta")
  if [ "$scenario" = missing ]; then rm "$tmp/xcrun"; else echo "$scenario" >"$tmp/mode"; fi
  run || { echo "expected $scenario to exit 0" >&2; exit 1; }
  [ "$(wc -l <"$tmp/err" | tr -d ' ')" = 1 ] || { echo "expected one warning for $scenario" >&2; exit 1; }
  if [ "$scenario" = fail ]; then
    grep -q "exit status 1" "$tmp/err" || { echo "expected export exit status in warning" >&2; exit 1; }
  fi
  diff -r "$tmp/state" "$tmp/snapshot"
  [ "$(readlink "$tmp/r1/beta")" = "$before" ]
  checklinks alpha beta gamma
  ;;
collision)
  mkdir -p "$tmp/r1/alpha" "$tmp/r2"
  echo mine >"$tmp/r1/alpha/keep"
  ln -s /nonexistent "$tmp/r2/alpha"
  run
  [ "$(cat "$tmp/r1/alpha/keep")" = mine ]
  [ "$(readlink "$tmp/r2/alpha")" = /nonexistent ]
  [ "$(wc -l <"$tmp/err" | tr -d ' ')" = 1 ]
  grep -q alpha "$tmp/err"
  checklinks beta gamma
  ;;
unrelated)
  mkdir -p "$tmp/r1"
  echo mine >"$tmp/r1/other"
  ln -s /nonexistent "$tmp/r1/dangling"
  run
  checklinks alpha beta gamma
  echo second >"$tmp/mode"
  run
  checklinks alpha gamma delta
  [ "$(cat "$tmp/r1/other")" = mine ]
  [ "$(readlink "$tmp/r1/dangling")" = /nonexistent ]
  ;;
release)
  run
  rm "$tmp/r1/alpha"
  ln -s /foreign "$tmp/r1/alpha"
  "$helper" --release --state "$tmp/state" --root "$tmp/r1" --root "$tmp/r2" --name alpha --name beta
  [ "$(readlink "$tmp/r1/alpha")" = /foreign ]
  [ ! -L "$tmp/r2/alpha" ]
  [ ! -L "$tmp/r1/beta" ]
  [ ! -L "$tmp/r2/beta" ]
  checklinks gamma
  ;;
root)
  run
  [ -d "$tmp/r1" ] && [ -d "$tmp/r2" ] || exit 1
  ;;
usage) if "$helper" --bogus >/dev/null 2>&1; then exit 1; fi ;;
esac
echo "$scenario passed"
