# capability-cache-identity.sh — the ONE derivation of a capability-cache identity,
# shared by .install-prerequisites.sh (the read-source-state.pre hook, which WRITES
# the record) and .chezmoitemplates/capabilities.tmpl (which READS it). Both sides
# must agree byte for byte, so neither owns a private copy.
#
# NOT A TEMPLATE and not a deployed target: it lives in .chezmoitemplates because
# capabilities.tmpl reads it as raw bytes and embeds it verbatim into a single
# `output "sh" "-c"` argument, so both sides run the same shell. Keep it POSIX sh.
#
# THE IDENTITY IS THE COMMAND, NOT THE PROCESS THAT ASKS. The caller — the hook
# shell, or the `sh` child chezmoi spawns for `output` — captures its own $PPID
# first, which is the chezmoi process itself, and passes it in
# CAPABILITY_CACHE_OWNER_PID. This file NEVER reads its own $$ / $PPID and never
# looks at command arguments: a helper that derived its own PID would give the hook
# and every template read a different identity, and one that hashed argv would let
# two simultaneous `chezmoi apply` runs share a snapshot. The pair (owner PID, that
# PID's immutable start marker) is what makes the identity per-COMMAND: a PID alone
# is recycled, and the start marker is the kernel's own tiebreaker.
#
# CONTRACT. Prints exactly one line and ALWAYS exits 0:
#
#   capability-cache-v1<TAB><owner pid><TAB><start marker><TAB><identity>
#   unresolved                       (nothing usable: bad/absent PID, no marker,
#                                     no SHA-256 tool)
#
# Exiting non-zero is not an option: chezmoi's `output` turns a non-zero child into
# a render-aborting template error, which would take down every chezmoi command on a
# host where the marker cannot be read. `unresolved` is the reader's cue to fall back
# to `unavailable`, and the hook's cue to fail closed.
#
# Set CAPABILITY_CACHE_IDENTITY_MAIN=0 to load the functions without emitting (the
# hook sources this file and calls capability_cache_identity_emit itself).

capability_cache_identity_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | cut -d' ' -f1
  else
    printf ''
  fi
}

# The owning process's start marker: immutable for the life of that process, so a
# recycled PID cannot inherit a previous command's record.
#   Linux : field 22 (starttime) of /proc/<pid>/stat, in clock ticks since boot.
#           The comm field (2) is parenthesized and MAY contain spaces and
#           parentheses, so the fields are counted after the LAST ')' — splitting on
#           whitespace from the start reads the wrong column for a process named
#           `(my cmd)`.
#   else  : `ps -o lstart=`, whitespace folded to '-' so it stays one TSV field.
#           LC_ALL=C is load-bearing: `lstart` is a LOCALISED date, so a Korean or
#           German session yields non-ASCII month/day names that the field-charset
#           guard below rejects — which would make every command on that host
#           unresolvable. `etime` would be ASCII but changes as the process runs,
#           so it cannot identify one.
capability_cache_identity_marker() {
  capability_cache_identity_marker_pid=$1
  capability_cache_identity_marker_value=''
  case "$(uname -s)" in
    Linux)
      if [ -r "/proc/$capability_cache_identity_marker_pid/stat" ]; then
        capability_cache_identity_marker_value=$(
          awk '{ sub(/^.*\) /, ""); print $20 }' \
            "/proc/$capability_cache_identity_marker_pid/stat" 2>/dev/null
        )
      fi
      ;;
    *)
      capability_cache_identity_marker_value=$(
        LC_ALL=C ps -o lstart= -p "$capability_cache_identity_marker_pid" 2>/dev/null |
          tr -s ' \t' '-' | tr -d '\n'
      )
      ;;
  esac
  [ -n "$capability_cache_identity_marker_value" ] || return 1
  printf '%s' "$capability_cache_identity_marker_value"
}

capability_cache_identity_emit() {
  capability_cache_identity_schema='capability-cache-v1'
  capability_cache_identity_pid=${CAPABILITY_CACHE_OWNER_PID:-}

  case "$capability_cache_identity_pid" in
    '' | *[!0-9]*)
      printf 'unresolved\n'
      return 0
      ;;
  esac

  capability_cache_identity_mark=$(
    capability_cache_identity_marker "$capability_cache_identity_pid"
  ) || {
    printf 'unresolved\n'
    return 0
  }

  # The marker lands in a tab-separated record field, so anything that could
  # introduce a tab, a newline or a shell metacharacter is refused rather than
  # sanitized: a marker we cannot represent exactly is not an identity.
  case "$capability_cache_identity_mark" in
    *[!A-Za-z0-9:._-]*)
      printf 'unresolved\n'
      return 0
      ;;
  esac

  # NUL-delimited, so no field value can impersonate a different field split.
  capability_cache_identity_value=$(
    printf '%s\0%s\0%s' \
      "$capability_cache_identity_schema" \
      "$capability_cache_identity_pid" \
      "$capability_cache_identity_mark" |
      capability_cache_identity_sha256
  )

  case "$capability_cache_identity_value" in
    '' | *[!0-9a-f]*)
      printf 'unresolved\n'
      return 0
      ;;
  esac

  printf '%s\t%s\t%s\t%s\n' \
    "$capability_cache_identity_schema" \
    "$capability_cache_identity_pid" \
    "$capability_cache_identity_mark" \
    "$capability_cache_identity_value"
}

if [ "${CAPABILITY_CACHE_IDENTITY_MAIN:-1}" = 1 ]; then
  capability_cache_identity_emit
fi
