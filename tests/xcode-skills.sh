#!/usr/bin/env bash
set -eu
helper=$1
scenario=${2:-all}
tmp=$(mktemp -d)
tmp=$(cd "$tmp" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
export STUB=$tmp
cat > "$tmp/xcrun" <<'STUB'
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
echo first > "$tmp/mode"
run() { "$helper" --install --xcrun "$tmp/xcrun" --state "$tmp/state" --root "$tmp/r1" --root "$tmp/r2" >"$tmp/out" 2>"$tmp/err"; }
checklinks() { for root in r1 r2; do for n in "$@"; do [ -L "$tmp/$root/$n" ] && [ "$(readlink "$tmp/$root/$n")" = "$tmp/state/$n" ] && [ "$(cat "$tmp/$root/$n/SKILL.md")" = "fixture $n" ] || return 1; done; done; }
case "$scenario" in
 all) for s in first update fail empty missing collision unrelated release root usage; do bash "$0" "$helper" "$s"; done; exit ;;
 first) run; checklinks alpha beta gamma; [ ! -s "$tmp/out" ] ;;
 update) run; echo second > "$tmp/mode"; run; checklinks alpha gamma delta; [ ! -L "$tmp/r1/beta" ] && [ ! -L "$tmp/r2/beta" ] && [ ! -e "$tmp/state/beta" ] || exit 1 ;;
 fail|empty|missing) run; cp -R "$tmp/state" "$tmp/snapshot"; before=$(readlink "$tmp/r1/beta"); if [ "$scenario" = missing ]; then rm "$tmp/xcrun"; else echo "$scenario" > "$tmp/mode"; fi; run; [ "$(wc -l < "$tmp/err" | tr -d ' ')" = 1 ]; diff -r "$tmp/state" "$tmp/snapshot"; [ "$(readlink "$tmp/r1/beta")" = "$before" ]; checklinks alpha beta gamma ;;
 collision) mkdir -p "$tmp/r1/alpha" "$tmp/r2"; echo mine > "$tmp/r1/alpha/keep"; ln -s /nonexistent "$tmp/r2/alpha"; run; [ "$(cat "$tmp/r1/alpha/keep")" = mine ]; [ "$(readlink "$tmp/r2/alpha")" = /nonexistent ]; [ "$(wc -l < "$tmp/err" | tr -d ' ')" = 1 ]; grep -q alpha "$tmp/err"; checklinks beta gamma ;;
 unrelated) mkdir -p "$tmp/r1"; echo mine > "$tmp/r1/other"; ln -s /nonexistent "$tmp/r1/dangling"; run; checklinks alpha beta gamma; echo second > "$tmp/mode"; run; checklinks alpha gamma delta; [ "$(cat "$tmp/r1/other")" = mine ]; [ "$(readlink "$tmp/r1/dangling")" = /nonexistent ] ;;
 release) run; rm "$tmp/r1/alpha"; ln -s /foreign "$tmp/r1/alpha"; "$helper" --release --state "$tmp/state" --root "$tmp/r1" --root "$tmp/r2" --name alpha --name beta; [ "$(readlink "$tmp/r1/alpha")" = /foreign ]; [ ! -L "$tmp/r2/alpha" ]; [ ! -L "$tmp/r1/beta" ]; [ ! -L "$tmp/r2/beta" ]; checklinks gamma ;;
 root) run; [ -d "$tmp/r1" ] && [ -d "$tmp/r2" ] || exit 1 ;;
 usage) if "$helper" --bogus >/dev/null 2>&1; then exit 1; fi ;;
esac
echo "$scenario passed"
