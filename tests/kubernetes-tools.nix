/*
  Check interface:

    import ./tests/kubernetes-tools.nix { inherit pkgs self fixtures; }

  Asserts that kubectl, helm, and minikube reach user `h82` with their zsh
  completions on every Home Manager user `tests/lib/configurations.nix` yields
  (NixOS and non-NixOS hosts, production and bootstrap alike).

  Each tool runs from home.path and must print its client version, because an
  existence test alone passes for a binary that exists but does not work.
  `bin/kubectl` must resolve into the kubectl package: the minikube package
  ships its own `bin/kubectl`, a link to minikube that downloads kubectl on
  first use. Each completion file must start with the `#compdef` line naming
  its command, so an empty or foreign file fails.

  Every lookup carries an `or` fallback so a mutation that removes a
  declaration reaches the builder as a failing assertion rather than an
  evaluation error. Each user runs in a subshell and records failures in a
  file, so one red build names every broken assertion.
*/
{
  pkgs,
  self,
  fixtures,
}:
let
  inherit (pkgs) lib;

  configurations = import ./lib/configurations.nix { inherit pkgs self fixtures; };

  esc = value: lib.escapeShellArg (toString value);

  assertEntry =
    entry:
    let
      homePath = entry.user.home.path or "";
    in
    ''
      checkUser ${esc entry.name} ${esc homePath}
    '';
in
pkgs.runCommand "kubernetes-tools-tests" { } ''
  ${configurations.userGuard}
  failures=$PWD/failures
  : > "$failures"

  checkUser() (
    user=$1 homePath=$2
    fail() { echo "$user: $*" >> "$failures"; }

    if [ -z "$homePath" ] || [ ! -d "$homePath/bin" ]; then
      fail "home-manager renders no home.path"
      exit
    fi
    bin=$homePath/bin

    work=$(mktemp -d)
    export HOME=$work/home
    mkdir -p "$HOME"

    # expectPrefix <tool> <prefix> <args...>: runs the tool and requires its
    # first output line to start with the prefix.
    expectPrefix() {
      tool=$1 prefix=$2
      shift 2
      if [ ! -x "$bin/$tool" ]; then
        fail "$tool is not in home.path"
        return
      fi
      actual=$("$bin/$tool" "$@" 2>&1) || { fail "$tool exited non-zero: $actual"; return; }
      case "$actual" in
        "$prefix"*) ;;
        *) fail "$tool printed '$actual', expected it to start with '$prefix'" ;;
      esac
    }

    expectPrefix kubectl "Client Version: v" version --client
    expectPrefix helm v version --short
    expectPrefix minikube v version --short

    resolved=$(readlink -f "$bin/kubectl")
    case "$resolved" in
      /nix/store/*-kubectl-*/bin/kubectl) ;;
      *) fail "bin/kubectl resolves to $resolved, not the kubectl package" ;;
    esac

    for command in kubectl helm minikube; do
      completion=$homePath/share/zsh/site-functions/_$command
      if [ ! -f "$completion" ]; then
        fail "no zsh completion for $command in home.path"
        continue
      fi
      first=$(head -n 1 "$completion")
      case "$first" in
        "#compdef $command"*) ;;
        *) fail "zsh completion for $command starts with '$first', not '#compdef $command'" ;;
      esac
    done
  )

  ${lib.concatMapStringsSep "\n" assertEntry configurations.userEntries}

  if [ -s "$failures" ]; then
    cat "$failures" >&2
    exit 1
  fi

  touch $out
''
