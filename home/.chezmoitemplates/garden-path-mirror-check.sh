# garden-path-mirror-check.sh — the ONE derivation of a ~/src project path from
# its clone url, shared by the apply-time gate in
# .chezmoiscripts/90-src/run_onchange_after_reconcile-garden.sh.tmpl (which
# inlines it) and .ci/test-garden-path-mirror-check.sh (which runs it directly).
# The rule itself is owned by the "Repository layout and garden ownership"
# section of .chezmoitemplates/agents-instructions.tmpl; this file only computes
# it.
#
# NOT A TEMPLATE and not a deployed target: it lives in .chezmoitemplates because
# that is the only directory includeTemplate can read. It is rendered as a Go
# template on the way in, so it must contain no brace-brace sequence.
# Keep it POSIX sh.
#
# WHY A STREAM AND NOT THE REGISTRY. The registry is GPG-encrypted and no CI
# runner holds the key or provisions garden (.ci/test-ci-wiring.sh records the
# latter). Parsing the registry here would make the checker untestable in CI.
# So the caller supplies already-parsed records and this file owns only the
# derivation and the comparison — the apply gate reads them from `garden ls`,
# the CI test writes them as literals.
#
# CONTRACT. `garden_path_mirror_records <root>` turns `garden ls -v` text on
# stdin into `name<TAB>abspath<TAB>relpath<TAB>url` records — one per declared
# tree, ALWAYS, even when the tree has no `origin:` line (its url column is then
# empty, which the check below reports as malformed). Emitting unconditionally is
# what keeps a remote-less tree from vanishing before the gates see it.
#
# `garden_path_mirror_check` reads tab-separated `name<TAB>declared-path<TAB>url` records on
# stdin, one per line. Declared paths are relative to the registry root; the
# caller reduces them before calling. Prints one line per deviation or malformed
# record on stderr and exits 1; prints nothing and exits 0 when every record
# conforms. With `--print` as the sole argument it instead prints the derived
# path of each record on stdout and exits 0 — the reversibility check uses this.
#
# DERIVATION. From a clone url: drop the scheme; drop any user@ userinfo; take
# the authority up to the first / (or, for the scp-like git@host:path form, up
# to the first :); drop a :port suffix from that authority; take the remainder
# as the namespace path; strip a leading / and a single trailing .git. No other
# segment is collapsed and case is preserved.

garden_path_mirror_records() {
  gpm_records_root=$1
  # `flush` runs at every boundary — the next header and end of input — so a
  # header with no `origin:` line still produces a record instead of being
  # overwritten. The root prefix is stripped with substr, not a regex, so a root
  # containing regex metacharacters cannot mis-strip it.
  awk -v root="$gpm_records_root/" '
    function flush() {
      if (name != "" && name != ".") {
        rel = path
        if (substr(rel, 1, length(root)) == root) {
          rel = substr(rel, length(root) + 1)
        }
        printf "%s\t%s\t%s\t%s\n", name, path, rel, url
      }
      name = ""
      path = ""
      url = ""
    }
    /^#-? / { flush(); name = $2; path = $NF; next }
    /^[[:space:]]+origin:[[:space:]]/ {
      if (name != "") { url = $2; flush() }
      next
    }
    END { flush() }
  '
}

# Count the tree headers in `garden ls -v` text on stdin, so a caller can prove
# every declared tree produced a record.
garden_path_mirror_header_count() {
  grep -c '^#-\{0,1\} ' || true
}

# Enumerate every declared tree as `name<TAB>abspath<TAB>relpath<TAB>url`
# records on stdout, or exit non-zero having explained why not. Both 90-src
# scripts need exactly this — the reconciler before its gate and grow, the
# registration script before it talks to Orca — and each still makes its own
# `garden ls` call at its own point in its own script; only the surrounding
# boilerplate lives here.
#
# $1 registry path, $2 log prefix, $3 the verb for the refusal message.
garden_path_mirror_enumerate() {
  gpm_en_reg=$1
  gpm_en_prefix=$2
  gpm_en_verb=$3

  gpm_en_raw="$(garden --config "$gpm_en_reg" ls --all --no-commands --no-gardens --no-groups -v 2>&1)" || {
    echo "$gpm_en_prefix: 'garden ls' failed — cannot enumerate declared trees:" >&2
    printf '%s\n' "$gpm_en_raw" >&2
    return 1
  }

  # A garden eval failure is reported, never swallowed: silently guessing the
  # root would strip nothing, and every tree would then fail the gate as
  # "outside the registry root" with the real cause invisible.
  if ! gpm_en_root="$(garden --config "$gpm_en_reg" eval '${GARDEN_ROOT}' 2>&1)"; then
    echo "$gpm_en_prefix: 'garden eval' could not resolve the registry root, falling back to \$HOME/src: $gpm_en_root" >&2
    gpm_en_root="$HOME/src"
  fi
  [ -n "$gpm_en_root" ] || gpm_en_root="$HOME/src"

  gpm_en_records="$(printf '%s\n' "$gpm_en_raw" | garden_path_mirror_records "$gpm_en_root")"

  # Every declared tree must have produced exactly one record. A `garden ls`
  # that succeeds but whose output this parser no longer recognizes would
  # otherwise leave every consumer iterating zero times — green, with nothing
  # checked.
  gpm_en_headers="$(printf '%s\n' "$gpm_en_raw" | garden_path_mirror_header_count)"
  gpm_en_count="$(printf '%s' "$gpm_en_records" | grep -c . || true)"
  if [ "$gpm_en_count" -ne "$gpm_en_headers" ] || [ "$gpm_en_headers" -eq 0 ]; then
    echo "$gpm_en_prefix: parsed $gpm_en_count records from $gpm_en_headers 'garden ls' tree headers — output format changed; refusing to $gpm_en_verb unverified" >&2
    return 1
  fi

  printf '%s\n' "$gpm_en_records"
}

garden_path_mirror_derive() {
  gpm_url=$1
  gpm_scheme=''

  case $gpm_url in
    *://*)
      gpm_scheme=${gpm_url%%://*}
      gpm_rest=${gpm_url#*://}
      ;;
    *)
      gpm_rest=$gpm_url
      ;;
  esac

  # Userinfo lives in the authority, which ends at the first slash.
  gpm_head=${gpm_rest%%/*}
  case $gpm_head in
    *@*) gpm_rest=${gpm_rest#*@} ;;
  esac

  if [ -n "$gpm_scheme" ]; then
    # scheme://host[:port]/namespace — the authority ends at the first slash.
    case $gpm_rest in
      */*) ;;
      *) return 1 ;;
    esac
    gpm_host=${gpm_rest%%/*}
    gpm_ns=${gpm_rest#*/}
  else
    # scp-like git@host:namespace, or a bare host/namespace.
    gpm_head=${gpm_rest%%/*}
    case $gpm_head in
      *:*)
        gpm_host=${gpm_rest%%:*}
        gpm_ns=${gpm_rest#*:}
        ;;
      *)
        case $gpm_rest in
          */*) ;;
          *) return 1 ;;
        esac
        gpm_host=${gpm_rest%%/*}
        gpm_ns=${gpm_rest#*/}
        ;;
    esac
  fi

  # A port is not a path segment. Strip it only when the remainder is numeric,
  # so a host name containing a colon-free label is never truncated.
  case $gpm_host in
    *:*)
      gpm_port=${gpm_host##*:}
      case $gpm_port in
        '' | *[!0-9]*) ;;
        *) gpm_host=${gpm_host%:*} ;;
      esac
      ;;
  esac

  gpm_ns=${gpm_ns#/}
  # Trailing slash first: `.../fleet.git/` must still lose its .git suffix.
  gpm_ns=${gpm_ns%/}
  case $gpm_ns in
    *.git) gpm_ns=${gpm_ns%.git} ;;
  esac
  gpm_ns=${gpm_ns%/}

  [ -n "$gpm_host" ] || return 1
  [ -n "$gpm_ns" ] || return 1

  printf '%s/%s' "$gpm_host" "$gpm_ns"
}

garden_path_mirror_check() {
  gpm_mode=${1:-check}
  gpm_rc=0
  # Computed once: an IFS command substitution in the loop test would fork a
  # subshell per record.
  gpm_tab=$(printf '\t')

  # `|| [ -n ... ]` so a final record with no trailing newline is still read.
  while IFS="$gpm_tab" read -r gpm_name gpm_declared gpm_url || [ -n "$gpm_name" ]; do
    [ -n "$gpm_name" ] || continue

    if [ -z "$gpm_url" ]; then
      echo "garden-path-mirror: '$gpm_name' declares no remote url — cannot derive its path" >&2
      gpm_rc=1
      continue
    fi

    if ! gpm_derived=$(garden_path_mirror_derive "$gpm_url"); then
      echo "garden-path-mirror: '$gpm_name' has a remote url no path can be derived from: $gpm_url" >&2
      gpm_rc=1
      continue
    fi

    if [ "$gpm_mode" = '--print' ]; then
      printf '%s\n' "$gpm_derived"
      continue
    fi

    case $gpm_declared in
      /*)
        echo "garden-path-mirror: '$gpm_name' declares a path outside the registry root: $gpm_declared" >&2
        gpm_rc=1
        continue
        ;;
    esac

    if [ "$gpm_declared" != "$gpm_derived" ]; then
      echo "garden-path-mirror: '$gpm_name' declares $gpm_declared but its remote derives $gpm_derived" >&2
      gpm_rc=1
    fi
  done

  return "$gpm_rc"
}

# Executed directly (the CI test) rather than sourced: run the check over stdin.
# The apply gate inlines this file and calls garden_path_mirror_check itself, so
# the guard keeps that inclusion from consuming stdin on its own.
if [ "${GARDEN_PATH_MIRROR_SOURCED:-}" != '1' ]; then
  garden_path_mirror_check "${1:-check}"
fi
