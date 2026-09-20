#!/usr/bin/env bash
# test-face-auth-node.sh — drive the rendered face-authentication installer
# against fixture camera trees and stub tools, and prove how it chooses the
# infrared node, what it tells Howdy about it, and when it reports the emitter
# configuration step.
#
# WHAT IT GUARDS. The installer used to find the infrared sensor by scanning
# /dev/video* for a node whose only pixel format was GREY. The ThinkPad's camera
# satisfies that; the MSI desktop's Realtek module streams MJPG/YUYV and does
# not, so the scan found nothing and the installer left through a harmless skip
# that removed its own record -- before it set Howdy's device or selected the
# authselect profile. Three properties are pinned here, one group per plan unit:
#
#   node    the node comes from the video nodes of an attached camera the
#           repository declared: a greyscale-only node first, otherwise the
#           format-capable node on the highest USB interface. A node whose
#           formats cannot be listed, or a camera with no usable node, resolves
#           nothing -- and the authselect feature is still selected, behind a
#           kept operator-blocking record.
#   emitter a stored capture is installed and read only under the resolved
#           device's own name. A camera with no capture of its own is measured,
#           and only the ALTERNATION counts: a camera whose emitters are dark
#           reads bright in a lit room, so brightness alone certifies nothing.
#   howdy   the device path is written only when a node was CONFIRMED infrared
#           -- by its format list, or by a stored instruction, or by strobing --
#           and the MJPEG capture option only when that node advertises no
#           greyscale format. Both writes are read-then-compare, so a second run
#           writes nothing.
#
# HOW IT RUNS. The installer is rendered through .ci/lib/render-gate-helpers.sh,
# its host facts are pinned and its absolute paths are rewritten into a fixture
# root, then it runs as bash under `env -i` with a PATH that names the stub
# directory and the system directories only. Every tool the installer reaches
# for -- sudo, dnf, rpm, systemctl, authselect, howdy, v4l2-ctl, ffmpeg -- is a
# stub that logs its argv, so no scenario can touch a package manager, the
# camera, PAM or /etc. /dev and /sys are reached through the installer's own
# FACE_AUTH_DEV_ROOT and FACE_AUTH_SYS_ROOT roots, because a fixture tree cannot
# hold character devices.
set -euo pipefail

repo_root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
prog=test-face-auth-node

fail() { printf '%s: FAIL: %s\n' "$prog" "$*" >&2; exit 1; }
pass() { printf '%s: ok - %s\n' "$prog" "$*"; }

command -v chezmoi >/dev/null 2>&1 || fail 'chezmoi is required on PATH'
chezmoi_bin=$(command -v chezmoi)

# shellcheck source=.ci/lib/render-scratch.sh
source "$repo_root/.ci/lib/render-scratch.sh"
# shellcheck source=.ci/lib/render-gate-helpers.sh
source "$repo_root/.ci/lib/render-gate-helpers.sh"
# shellcheck source=.ci/lib/source-root.sh
source "$repo_root/.ci/lib/source-root.sh"
source_root=$(resolve_source_root "$repo_root")
setup_render_scratch face-auth-node
scratch=$(readlink -f "$scratch")

installer_src=.chezmoiscripts/30-linux/run_onchange_after_install-system-34-face-auth.sh.tmpl
capture_dir=system/linux/etc/linux-enable-ir-emitter
thinkpad_by_path='pci-0000:00:14.0-usb-0:8:1.2-video-index0'
desktop_by_path='pci-0000:00:14.0-usb-0:5.1.1:1.2-video-index0'
require_file "$repo_root" "$scratch" "$chezmoi_bin" "$installer_src"
[[ -f "$repo_root/$capture_dir/$thinkpad_by_path" ]] ||
  fail "the ThinkPad capture $capture_dir/$thinkpad_by_path is not committed"
grep -q 'status: start' "$repo_root/$capture_dir/$thinkpad_by_path" ||
  fail 'the committed ThinkPad capture carries no status: start instruction'

# --- Render the installer, then pin its facts and paths -------------------------

host=$scratch/host
rendered=$scratch/installer.rendered.sh
runnable=$scratch/installer.sh
fedora_data='{"chezmoi":{"os":"linux","arch":"amd64","username":"fixture","osRelease":{"id":"fedora"}}}'
render "$repo_root" "$scratch" "$chezmoi_bin" linux "$source_root/$installer_src" "$rendered" "$fedora_data" ||
  fail 'the face-authentication installer did not render'
bash -n "$rendered" || fail 'the rendered installer is not valid bash'
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning "$rendered" || fail 'the rendered installer fails shellcheck'
fi

# The FACT_* block is baked from the host that rendered it, so the four facts
# the installer's guards read are pinned; each rewrite is asserted to have
# landed, because a sed that matches nothing would leave the host's own value.
sed -e 's#^  FACT_IR_CAMERA=.*#  FACT_IR_CAMERA=1#' \
  -e 's#^  FACT_HEADLESS=.*#  FACT_HEADLESS=0#' \
  -e 's#^  FACT_SHARED_HOST=.*#  FACT_SHARED_HOST=0#' \
  -e 's#^  FACT_DISPLAY_MANAGER=.*#  FACT_DISPLAY_MANAGER=plasmalogin#' \
  -e "s#/etc/#$host/etc/#g" \
  -e "s#\\(\\\$SRC_ROOT\"\\{0,1\\}\\)$host/etc/#\\1/etc/#g" \
  -e "s#/usr/share/authselect#$host/usr/share/authselect#g" \
  -e "s#/usr/lib/pam.d#$host/usr/lib/pam.d#g" \
  -e "s#/usr/local/bin/#$host/usr/local/bin/#g" \
  "$rendered" >"$runnable"
for pin in '  FACT_IR_CAMERA=1' '  FACT_HEADLESS=0' '  FACT_SHARED_HOST=0' '  FACT_DISPLAY_MANAGER=plasmalogin'; do
  grep -qxF -- "$pin" "$runnable" || fail "the fact pin '$pin' did not land in the rendered installer"
done
grep -qF -- "$host/etc/howdy/config.ini" "$runnable" ||
  fail 'the rendered installer no longer reads /etc/howdy/config.ini; the path rewrite proves nothing'
# The committed captures live under the source tree, which the rewrite must not
# move: a rewrite that reached them would leave every capture "not committed".
grep -qE '\$SRC_ROOT"?/etc/linux-enable-ir-emitter/' "$runnable" ||
  fail 'the rewrite moved the committed-capture path under $SRC_ROOT'

# --- Stubs ---------------------------------------------------------------------

stubs=$scratch/stubs
mkdir -p "$stubs"
write_stub() {
  local name=$1
  cat >"$stubs/$name"
  chmod 755 "$stubs/$name"
}

write_stub sudo <<'STUB'
#!/usr/bin/env bash
while [[ ${1-} == -* ]]; do shift; done
exec "$@"
STUB

write_stub dnf <<'STUB'
#!/usr/bin/env bash
printf 'dnf %s\n' "$*" >>"$FIXTURE_LOG"
[[ ${1-} == copr && ${2-} == list ]] && printf 'copr.fedorainfracloud.org/starfish/howdy-beta\n'
exit 0
STUB

write_stub rpm <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

write_stub systemctl <<'STUB'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$FIXTURE_LOG"
exit 0
STUB

write_stub authselect <<'STUB'
#!/usr/bin/env bash
case ${1-} in
  current) cat "$FIXTURE_ROOT/authselect.current" ;;
  check) ;;
  test) cat "$FIXTURE_ROOT/authselect.test" ;;
  select)
    printf 'authselect %s\n' "$*" >>"$FIXTURE_LOG"
    shift
    printf '%s\n' "$*" >"$FIXTURE_ROOT/authselect.current"
    ;;
  *) printf 'authselect %s\n' "$*" >>"$FIXTURE_LOG" ;;
esac
STUB

write_stub howdy <<'STUB'
#!/usr/bin/env bash
printf 'howdy %s\n' "$*" >>"$FIXTURE_LOG"
[[ ${1-} == set ]] || exit 0
config="$FIXTURE_ROOT/etc/howdy/config.ini"
if grep -q "^$2 = " "$config"; then
  sed -i "s|^$2 = .*|$2 = $3|" "$config"
else
  printf '%s = %s\n' "$2" "$3" >>"$config"
fi
STUB

# v4l2-ctl answers from one spec file per node: a line per format, `<FOURCC>
# <WxH>`. `FAIL` makes it exit non-zero the way a broken tool would, and a node
# with no spec file behaves as an unreadable device.
write_stub v4l2-ctl <<'STUB'
#!/usr/bin/env bash
node='' mode=''
while (($#)); do
  case $1 in
    -d) node=$2; shift ;;
    --list-formats-ext) mode=ext ;;
    --list-formats) mode=fmt ;;
  esac
  shift
done
printf 'v4l2-ctl %s %s\n' "$node" "$mode" >>"$FIXTURE_LOG"
spec="$FIXTURE_ROOT/v4l2/${node##*/}"
if [[ ! -r $spec ]]; then
  printf 'Failed to open %s: No such file or directory\n' "$node" >&2
  exit 1
fi
if grep -qx FAIL "$spec"; then
  printf 'VIDIOC_ENUM_FMT: Inappropriate ioctl for device\n' >&2
  exit 1
fi
printf 'ioctl: VIDIOC_ENUM_FMT\n\tType: Video Capture\n\n'
index=0
while read -r fourcc size; do
  [[ -n $fourcc ]] || continue
  printf "\t[%d]: '%s' (fixture format)\n" "$index" "$fourcc"
  if [[ $mode == ext ]]; then
    printf '\t\tSize: Discrete %s\n\t\t\tInterval: Discrete 0.033s (30.000 fps)\n' "$size"
  fi
  index=$((index + 1))
done <"$spec"
STUB

# ffmpeg writes raw greyscale frames whose means follow ffmpeg.means (cycled),
# or fails, or writes nothing, per ffmpeg.mode. It records its argv, which is
# how a scenario proves the brightness test ran, or never ran.
write_stub ffmpeg <<'STUB'
#!/usr/bin/env bash
printf 'ffmpeg %s\n' "$*" >>"$FIXTURE_LOG"
[[ ${*: -1} == pipe:1 ]] || { printf 'ffmpeg stub: expected the frames on pipe:1\n' >&2; exit 2; }
size='' frames=10
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case ${args[i]} in
    -video_size) size=${args[i + 1]} ;;
    -frames:v) frames=${args[i + 1]} ;;
  esac
done
mode=ok
[[ -r $FIXTURE_ROOT/ffmpeg.mode ]] && mode=$(<"$FIXTURE_ROOT/ffmpeg.mode")
case $mode in
  fail)
    printf 'ffmpeg: cannot open the capture device\n' >&2
    exit 1
    ;;
  empty) exit 0 ;;
esac
read -r -a means <"$FIXTURE_ROOT/ffmpeg.means"
bytes=$((${size%x*} * ${size#*x}))
for ((i = 0; i < frames; i++)); do
  value=${means[$((i % ${#means[@]}))]}
  if ((value == 0)); then
    head -c "$bytes" /dev/zero
  else
    head -c "$bytes" /dev/zero | tr '\0' "$(printf '\\%03o' "$value")"
  fi
done
STUB

# --- Fixture host --------------------------------------------------------------

new_host() {
  rm -rf "$host"
  mkdir -p "$host"/{dev/v4l/by-path,sys/class/video4linux,sys/devices,v4l2,tmp,state,home} \
    "$host"/etc/{pam.d,howdy/models} "$host"/usr/local/bin "$host"/usr/lib/pam.d \
    "$host"/usr/share/authselect/default/local \
    "$host"/repo/home "$host/repo/$capture_dir"
  : >"$host/calls.log"
  : >"$host/repo/.chezmoiroot"
  cp "$repo_root/$capture_dir/$thinkpad_by_path" "$host/repo/$capture_dir/"

  printf '#!/usr/bin/env bash\nprintf "linux-enable-ir-emitter 99.0.0\\n"\n' >"$host/usr/local/bin/linux-enable-ir-emitter"
  chmod 755 "$host/usr/local/bin/linux-enable-ir-emitter"

  base=$host/usr/share/authselect/default/local
  printf 'auth        sufficient                                   pam_fprintd.so {include if "with-fingerprint"}\nauth        sufficient                                   pam_unix.so\n' >"$base/system-auth"
  printf 'auth        required                                     pam_env.so\nauth        sufficient                                   pam_unix.so\n' >"$base/password-auth"
  printf 'Stock local profile.\n' >"$base/README"

  printf 'auth       substack     password-auth\n' >"$host/etc/pam.d/plasmalogin"
  printf 'auth       required     pam_env.so\nauth       sufficient   pam_unix.so\n' >"$host/etc/pam.d/password-auth"
  {
    printf 'File %s/etc/pam.d/system-auth:\n' "$host"
    printf 'auth        sufficient                                   pam_howdy.so\n'
    printf 'auth        sufficient                                   pam_fprintd.so\n'
    printf 'File %s/etc/pam.d/password-auth:\n' "$host"
    printf 'auth        required                                     pam_env.so\n'
  } >"$host/authselect.test"
  printf 'local with-fingerprint\n' >"$host/authselect.current"

  printf '[video]\ndevice_path = none\nforce_mjpeg = false\n' >"$host/etc/howdy/config.ini"
  # An enrolled face, so a converged run has no manual step left to report.
  printf 'model\n' >"$host/etc/howdy/models/fixture.dat"
  printf 'ok\n' >"$host/ffmpeg.mode"
  printf '67 79\n' >"$host/ffmpeg.means"
}

# add_node <vendor> <product> <usb device> <interface> <video node> <by-path
# name> <format spec>. The node reaches its camera the way the kernel exposes
# it: class/video4linux/<node>/device is the USB interface directory, whose
# parent carries idVendor and idProduct.
add_node() {
  local vendor=$1 product=$2 usbdev=$3 interface=$4 node=$5 by_path=$6 spec=$7
  local usbdir=$host/sys/devices/pci/$usbdev
  local ifdir=$usbdir/$usbdev:1.$interface
  mkdir -p "$ifdir" "$host/sys/class/video4linux/$node"
  printf '%s\n' "$vendor" >"$usbdir/idVendor"
  printf '%s\n' "$product" >"$usbdir/idProduct"
  ln -s "$ifdir" "$host/sys/class/video4linux/$node/device"
  : >"$host/dev/$node"
  ln -sfn "../../$node" "$host/dev/v4l/by-path/$by_path"
  ln -sfn "../../$node" "$host/dev/v4l/by-path/${by_path/-usb-/-usbv2-}"
  printf '%b' "$spec" >"$host/v4l2/$node"
}

# The ThinkPad module: an RGB node and its metadata node on interface 0, and an
# infrared node that enumerates only GREY on interface 2.
thinkpad_host() {
  new_host
  add_node 30c9 0052 1-8 0 video0 'pci-0000:00:14.0-usb-0:8:1.0-video-index0' 'MJPG 640x480\nYUYV 640x480\n'
  add_node 30c9 0052 1-8 0 video1 'pci-0000:00:14.0-usb-0:8:1.0-video-index1' ''
  add_node 30c9 0052 1-8 2 video2 "$thinkpad_by_path" 'GREY 340x340\n'
  add_node 30c9 0052 1-8 2 video3 'pci-0000:00:14.0-usb-0:8:1.2-video-index1' ''
}

# The MSI desktop's Realtek module: nothing on it advertises greyscale, the
# infrared function is on interface 2, and each interface has a metadata node
# that enumerates no capture format.
desktop_host() {
  new_host
  add_node 0bda 571d 1-5.1.1 0 video0 'pci-0000:00:14.0-usb-0:5.1.1:1.0-video-index0' 'MJPG 640x480\nYUYV 640x360\n'
  add_node 0bda 571d 1-5.1.1 0 video1 'pci-0000:00:14.0-usb-0:5.1.1:1.0-video-index1' ''
  add_node 0bda 571d 1-5.1.1 2 video2 "$desktop_by_path" 'MJPG 640x480\nYUYV 640x360\n'
  add_node 0bda 571d 1-5.1.1 2 video3 'pci-0000:00:14.0-usb-0:5.1.1:1.2-video-index1' ''
}

run_installer() {
  rc=0
  env -i HOME="$host/home" PATH="$stubs:/usr/bin:/bin" TMPDIR="$host/tmp" \
    XDG_STATE_HOME="$host/state" USER=fixture LC_ALL=C \
    CHEZMOI_SOURCE_DIR="$host/repo/home" FIXTURE_ROOT="$host" FIXTURE_LOG="$host/calls.log" \
    FACE_AUTH_DEV_ROOT="$host/dev" FACE_AUTH_SYS_ROOT="$host/sys" \
    bash "$runnable" >"$host/out.txt" 2>"$host/err.txt" || rc=$?
}

# --- Assertions ----------------------------------------------------------------

show_run() { printf -- '--- stdout ---\n%s\n--- stderr ---\n%s\n--- calls ---\n%s\n' \
  "$(cat "$host/out.txt")" "$(cat "$host/err.txt")" "$(cat "$host/calls.log")"; }
out_has() { grep -qF -- "$1" "$host/out.txt" "$host/err.txt"; }
expect_out() { out_has "$1" || fail "$2: expected the output to contain: $1
$(show_run)"; }
expect_no_out() { ! out_has "$1" || fail "$2: expected the output NOT to contain: $1
$(show_run)"; }
log_count() { grep -cF -- "$1" "$host/calls.log" || true; }
expect_calls() {
  local want=$1 pattern=$2 label=$3 got
  got=$(log_count "$pattern")
  [[ $got -eq $want ]] || fail "$label: expected $want call(s) matching '$pattern', saw $got
$(show_run)"
}
expect_rc0() { [[ $rc -eq 0 ]] || fail "$1: the installer exited $rc
$(show_run)"; }
skip_record="$host/state/chezmoi/skips/install-system-face-auth__no-infrared-node"
expect_kept_record() {
  [[ -f $skip_record ]] || fail "$1: no kept no-infrared-node record was written
$(show_run)"
  [[ "$(cut -f4 "$skip_record")" == operator-blocking ]] ||
    fail "$1: the no-infrared-node record is not operator-blocking: $(cat "$skip_record")"
}
expect_no_records() {
  local leftovers
  leftovers=$(find "$host/state/chezmoi/skips" -type f -name 'install-system-face-auth__*' 2>/dev/null || true)
  [[ -z $leftovers ]] || fail "$1: face-authentication records are still listed: $leftovers"
}
expect_authselect_selected() {
  expect_calls 1 'authselect select custom/face-auth' "$1 (the authselect feature is still provisioned)"
}
installed_captures() { ls -A "$host/etc/linux-enable-ir-emitter" 2>/dev/null || true; }

# =============================================================================
# U1 -- the greeter guard
# =============================================================================

# Gap: every fixture below renders a clean greeter stack, so
# greeter_would_gain_module never returns true and the withhold branch has
# never run -- deleting the guard from the installer would leave every other
# scenario green. Render the greeter's own included stack (plasmalogin
# substacks password-auth) as authselect would carry pam_howdy.so, and prove
# the installer takes the greeter-would-gain-face site instead of selecting
# the profile or pointing Howdy at a camera.
desktop_host
{
  printf 'File %s/etc/pam.d/system-auth:\n' "$host"
  printf 'auth        sufficient                                   pam_howdy.so\n'
  printf 'auth        sufficient                                   pam_fprintd.so\n'
  printf 'File %s/etc/pam.d/password-auth:\n' "$host"
  printf 'auth        sufficient                                   pam_howdy.so\n'
  printf 'auth        required                                     pam_env.so\n'
} >"$host/authselect.test"
cp "$host/etc/howdy/config.ini" "$host/config.before"
run_installer
expect_rc0 'greeter withhold'
expect_out 'the login greeter authentication stack would reach the face module' 'greeter withhold takes the greeter-would-gain-face site'
expect_calls 0 'authselect select' 'greeter withhold never selects the face profile'
expect_calls 0 'howdy set' 'greeter withhold never writes to /etc/howdy/config.ini'
cmp -s "$host/etc/howdy/config.ini" "$host/config.before" || fail 'greeter withhold: /etc/howdy/config.ini changed although the profile was withheld'
pass 'U1: a greeter stack that would gain pam_howdy.so withholds the face profile and leaves Howdy untouched'

# =============================================================================
# U2 -- node resolution
# =============================================================================

# AE1: a camera whose infrared node advertises only greyscale keeps today's choice.
thinkpad_host
run_installer
expect_rc0 'AE1'
expect_out "infrared node $host/dev/video2 of camera 30c9:0052" 'AE1 the chosen node and its camera are printed'
expect_calls 1 "howdy set device_path $host/dev/v4l/by-path/$thinkpad_by_path" 'AE1 Howdy reads the by-path link of that node'
expect_no_records 'AE1'
pass 'AE1: a greyscale-only infrared node is chosen and named with its camera'

# Greyscale is the first signal: a GREY-only node wins over a format-capable node
# on a higher interface.
new_host
add_node 30c9 0052 1-8 0 video0 'pci-0000:00:14.0-usb-0:8:1.0-video-index0' 'GREY 340x340\n'
add_node 30c9 0052 1-8 2 video2 "$thinkpad_by_path" 'MJPG 640x480\nYUYV 640x480\n'
run_installer
expect_rc0 'greyscale precedence'
expect_out "infrared node $host/dev/video0 of camera 30c9:0052" 'greyscale precedence'
expect_calls 1 "ffmpeg -nostdin -loglevel error -f v4l2 -input_format gray -video_size 340x340 -i $host/dev/video0" 'greyscale precedence the emitter probe reads GREY frames from the GREY-only node, with no committed capture'
pass 'a greyscale-only node outranks a format-capable node on a higher interface'

# AE2: no greyscale anywhere, so the later video-streaming function is chosen.
desktop_host
run_installer
expect_rc0 'AE2'
expect_out "infrared node $host/dev/video2 of camera 0bda:571d" 'AE2 the interface-2 node is chosen'
expect_no_out "infrared node $host/dev/video0 " 'AE2 the RGB node is not chosen'
expect_calls 1 "howdy set device_path $host/dev/v4l/by-path/$desktop_by_path" 'AE2 Howdy reads the plain by-path link of the chosen node'
expect_calls 0 'usbv2' 'AE2 the usbv2 spelling is never written into the Howdy config'
expect_no_records 'AE2'
pass 'AE2: a camera with no greyscale node resolves its interface-2 node, not the RGB one'

# AE3: a declared camera's node is chosen; an undeclared camera's is never
# consulted, even when it advertises greyscale.
desktop_host
add_node 1234 abcd 1-9 2 video4 'pci-0000:00:14.0-usb-0:9:1.2-video-index0' 'GREY 640x480\n'
run_installer
expect_rc0 'AE3'
expect_out "infrared node $host/dev/video2 of camera 0bda:571d" 'AE3 the declared camera wins'
expect_calls 0 "v4l2-ctl $host/dev/video4" 'AE3 no node of the undeclared camera is even enumerated'
pass 'AE3: an undeclared camera beside a declared one is never chosen'

new_host
add_node 1234 abcd 1-9 2 video4 'pci-0000:00:14.0-usb-0:9:1.2-video-index0' 'GREY 640x480\n'
run_installer
expect_rc0 'AE3 undeclared only'
expect_kept_record 'AE3 undeclared only'
expect_calls 0 'howdy set' 'AE3 undeclared only never writes the Howdy config'
pass 'AE3: an undeclared camera alone resolves nothing'

# AE4: a declared camera with no capture-capable node is an unconverged host:
# the authselect feature is still selected and the kept record lists it.
desktop_host
for node in video0 video1 video2 video3; do : >"$host/v4l2/$node"; done
cp "$host/etc/howdy/config.ini" "$host/config.before"
run_installer
expect_rc0 'AE4'
expect_authselect_selected 'AE4'
expect_kept_record 'AE4'
expect_calls 0 'howdy set' 'AE4 a host with no node never writes /etc/howdy/config.ini'
cmp -s "$host/etc/howdy/config.ini" "$host/config.before" || fail 'AE4: /etc/howdy/config.ini changed although no node resolved'
expect_out '0bda:571d' 'AE4 the camera is named'
expect_out "$host/dev/video2: no capture formats" 'AE4 the nodes it saw are named'
expect_no_out 'manual step' 'AE4 no manual step is reported for a host with no node'
pass 'AE4: a declared camera with no usable node keeps its record after the authselect feature is selected'

# A v4l2-ctl that exits non-zero is an error to print, never "no formats".
desktop_host
printf 'FAIL\n' >"$host/v4l2/video2"
run_installer
expect_rc0 'v4l2-ctl failure'
expect_out 'VIDIOC_ENUM_FMT: Inappropriate ioctl for device' 'v4l2-ctl failure the tool error is printed'
expect_out "$host/dev/video2" 'v4l2-ctl failure names the node it failed on'
expect_no_out "infrared node $host/dev" 'v4l2-ctl failure the RGB node is not taken instead'
expect_kept_record 'v4l2-ctl failure'
expect_authselect_selected 'v4l2-ctl failure'
expect_calls 0 'howdy set' 'v4l2-ctl failure never writes the Howdy config'
pass 'a failing v4l2-ctl is reported and resolves no node'

# A later run that resolves the node retires the kept record.
desktop_host
mkdir -p "$(dirname "$skip_record")"
printf 'v1\tinstall-system-face-auth\tno-infrared-node\toperator-blocking\tstale\n' >"$skip_record"
run_installer
expect_rc0 'record retirement'
[[ ! -e $skip_record ]] || fail 'a resolved node left the stale no-infrared-node record behind'
pass 'resolving the node retires the kept record'

# Gap: a camera whose infrared node lists no capture formats must not end up
# with Howdy pointed at its RGB sibling instead. The RGB node becomes the only
# surviving candidate and is picked positionally, so it still needs the proof
# gate's confirmation -- a flat, dark capture withholds it.
new_host
add_node 0bda 571d 1-5.1.1 0 video0 'pci-0000:00:14.0-usb-0:5.1.1:1.0-video-index0' 'MJPG 640x480\nYUYV 640x360\n'
add_node 0bda 571d 1-5.1.1 0 video1 'pci-0000:00:14.0-usb-0:5.1.1:1.0-video-index1' ''
add_node 0bda 571d 1-5.1.1 2 video2 "$desktop_by_path" ''
add_node 0bda 571d 1-5.1.1 2 video3 'pci-0000:00:14.0-usb-0:5.1.1:1.2-video-index1' ''
printf '6\n' >"$host/ffmpeg.means"
run_installer
expect_rc0 'no-format IR node does not promote its RGB sibling'
expect_out "$host/dev/video2: no capture formats" 'the no-format IR node is reported and skipped'
expect_out "infrared node $host/dev/video0 of camera 0bda:571d" 'the RGB node is the only remaining candidate and is picked positionally'
expect_calls 0 'howdy set' 'the RGB sibling is never accepted or pointed at by Howdy'
expect_kept_record 'no-format IR node does not promote its RGB sibling'
pass 'a camera whose infrared node lists no capture formats does not promote its RGB sibling past the proof gate'

# =============================================================================
# U3 -- the emitter expectation
# =============================================================================

# AE5: no stored configuration for this camera, and its emitters strobe.
desktop_host
printf '67 79\n' >"$host/ffmpeg.means"
run_installer
expect_rc0 'AE5'
expect_calls 1 "ffmpeg -nostdin -loglevel error -f v4l2 -input_format mjpeg -video_size 640x480 -i $host/dev/video2" 'AE5 the burst is captured from the chosen node in the format it delivers'
expect_no_out 'linux-enable-ir-emitter configure' 'AE5 no emitter step is reported'
expect_no_out 'manual step' 'AE5 an enrolled, operating host has no manual step'
[[ -z "$(installed_captures)" ]] || fail "AE5: the ThinkPad capture landed on the desktop: $(installed_captures)"
expect_no_records 'AE5'
pass 'AE5: alternating frame brightness means the emitters operate and no emitter step is reported'

# Gap: the proof gate's strobe-accept outcome above only checks that no manual
# step is reported; it never asserts that Howdy is actually pointed at the
# confirmed node, or that no unconverged record survives.
desktop_host
printf '67 79\n' >"$host/ffmpeg.means"
run_installer
expect_rc0 'proof gate: strobe accepted'
expect_calls 1 "howdy set device_path $host/dev/v4l/by-path/$desktop_by_path" 'proof gate: strobe accepted points Howdy at the confirmed node'
expect_no_records 'proof gate: strobe accepted'
pass 'a positional node whose capture strobes is accepted: Howdy is pointed at it and no record is kept'

# Gap: emitters_operating picks its ffmpeg input format from what the node
# advertises; only the MJPG branch above is exercised. A YUYV-only node.
new_host
add_node 0bda 571d 1-5.1.1 0 video0 'pci-0000:00:14.0-usb-0:5.1.1:1.0-video-index0' 'YUYV 640x360\n'
add_node 0bda 571d 1-5.1.1 0 video1 'pci-0000:00:14.0-usb-0:5.1.1:1.0-video-index1' ''
add_node 0bda 571d 1-5.1.1 2 video2 "$desktop_by_path" 'YUYV 640x360\n'
add_node 0bda 571d 1-5.1.1 2 video3 'pci-0000:00:14.0-usb-0:5.1.1:1.2-video-index1' ''
run_installer
expect_rc0 'YUYV-only emitter probe'
expect_out "infrared node $host/dev/video2 of camera 0bda:571d" 'YUYV-only emitter probe the interface-2 node is chosen'
expect_calls 1 "ffmpeg -nostdin -loglevel error -f v4l2 -input_format yuyv422 -video_size 640x360 -i $host/dev/video2" 'YUYV-only emitter probe reads YUYV frames with -input_format yuyv422'
pass 'a YUYV-only node probes the emitters with -input_format yuyv422'

# A node advertising only a fourth format this probe does not decode reports
# why. It was picked by interface number, so it is never confirmed to be the
# infrared sensor -- a node this script cannot even decode certainly is not --
# and the proof gate refuses it rather than pointing Howdy at it.
new_host
add_node 0bda 571d 1-5.1.1 0 video0 'pci-0000:00:14.0-usb-0:5.1.1:1.0-video-index0' 'MJPG 640x480\n'
add_node 0bda 571d 1-5.1.1 0 video1 'pci-0000:00:14.0-usb-0:5.1.1:1.0-video-index1' ''
add_node 0bda 571d 1-5.1.1 2 video2 "$desktop_by_path" 'H264 640x480\n'
add_node 0bda 571d 1-5.1.1 2 video3 'pci-0000:00:14.0-usb-0:5.1.1:1.2-video-index1' ''
run_installer
expect_rc0 'unrecognized-format emitter probe'
expect_out "infrared node $host/dev/video2 of camera 0bda:571d" 'unrecognized-format emitter probe the interface-2 node is still chosen'
expect_out 'advertises no format this probe decodes (H264)' 'unrecognized-format emitter probe names the format it cannot decode'
expect_calls 0 'ffmpeg' 'unrecognized-format emitter probe never invokes ffmpeg'
expect_calls 0 'howdy set' 'an undecodable node is never written into the Howdy config'
expect_kept_record 'unrecognized-format emitter probe'
expect_authselect_selected 'unrecognized-format emitter probe'
pass 'a node advertising a format the probe does not decode reports it and asks for manual configuration'

# A uniformly dark sensor on a camera with no greyscale node needs a
# configuration, and until it has one the node it picked by interface number is
# not confirmed to be the infrared sensor. The host is therefore recorded
# unconverged and Howdy is not pointed at it -- the kept record, unlike the
# one-shot manual-step report, survives to the next apply and names the fix.
desktop_host
printf '6\n' >"$host/ffmpeg.means"
run_installer
expect_rc0 'dark'
expect_out 'did not strobe' 'a dark sensor on a positionally-picked node is not confirmed'
expect_kept_record 'dark'
expect_authselect_selected 'dark'
expect_calls 0 'howdy set' 'an unconfirmed node is never written into the Howdy config'
pass 'a uniformly dark capture reports the configure step'

# The threshold is the ALTERNATION alone: a difference of 8 between consecutive
# frames. Brightness by itself certifies nothing, because a camera whose
# emitters are dark reads bright in a lit room, and accepting that would report
# a converged host while the operator is never told to run `configure`.
threshold_case() {
  local means=$1 want=$2
  desktop_host
  printf '%s\n' "$means" >"$host/ffmpeg.means"
  run_installer
  expect_rc0 "threshold $means"
  if [[ $want == operating ]]; then
    expect_no_out 'linux-enable-ir-emitter configure' "threshold '$means' should read as operating"
  else
    expect_out 'linux-enable-ir-emitter configure' "threshold '$means' should read as dark"
  fi
}
threshold_case '5 13' operating
threshold_case '5 12' dark
# A flat capture is inconclusive however bright it is.
threshold_case '20' dark
threshold_case '200' dark
threshold_case '19' dark
pass 'the emitter verdict rests on a frame-to-frame difference of 8, never on brightness alone'

# Gap: a status: start configuration already on the HOST for the resolved
# device's own name accepts a positional node without ever measuring it --
# distinct from AE6 below, which installs a capture from the committed source
# tree first. Here the file is already live, as a previous manual `configure`
# run would have left it.
desktop_host
mkdir -p "$host/etc/linux-enable-ir-emitter"
printf 'status: start\n' >"$host/etc/linux-enable-ir-emitter/$desktop_by_path"
run_installer
expect_rc0 'proof gate: stored configuration accepted'
expect_calls 0 'ffmpeg' 'proof gate: stored configuration accepted never measures the node'
expect_calls 1 "howdy set device_path $host/dev/v4l/by-path/$desktop_by_path" 'proof gate: stored configuration accepted points Howdy at the node'
expect_no_records 'proof gate: stored configuration accepted'
pass 'a positional node with a stored configuration for its own device is accepted without any strobe measurement'

# AE6: the ThinkPad's committed capture and camera. The capture is installed
# unchanged, applied, and the brightness test never runs.
thinkpad_host
run_installer
expect_rc0 'AE6'
[[ "$(installed_captures)" == "$thinkpad_by_path" ]] || fail "AE6: expected exactly the ThinkPad capture to be installed, found: $(installed_captures)"
cmp -s "$repo_root/$capture_dir/$thinkpad_by_path" "$host/etc/linux-enable-ir-emitter/$thinkpad_by_path" ||
  fail 'AE6: the installed capture differs from the committed one'
expect_calls 0 'ffmpeg' 'AE6 the brightness test never runs for a camera with a stored configuration'
expect_calls 1 'systemctl start linux-enable-ir-emitter.service' 'AE6 the emitter unit is re-asserted'
expect_no_out 'linux-enable-ir-emitter configure' 'AE6 no emitter step is reported'
pass 'AE6: the ThinkPad capture is installed byte-identical and the brightness test is skipped'

# A capture for another camera is never installed, and never read as this one's
# configuration: the desktop reaches the brightness test with only the
# ThinkPad's capture committed.
desktop_host
run_installer
expect_rc0 'foreign capture'
[[ -z "$(installed_captures)" ]] || fail "a capture named for another device was installed: $(installed_captures)"
expect_calls 1 'ffmpeg' 'a foreign capture leaves the brightness test to run'
pass 'a capture committed for another device is neither installed nor counted'

# A capture already on the host for another device must not read as this one's
# configuration either.
desktop_host
mkdir -p "$host/etc/linux-enable-ir-emitter"
cp "$repo_root/$capture_dir/$thinkpad_by_path" "$host/etc/linux-enable-ir-emitter/"
printf '6\n' >"$host/ffmpeg.means"
run_installer
expect_rc0 'directory-wide status'
# The foreign file must not confirm this camera either: with it present and this
# camera's own capture dark, the node stays unconfirmed and the host unconverged.
expect_out 'did not strobe' "another device's status: start must not satisfy this camera"
expect_kept_record 'directory-wide status'
expect_calls 0 'howdy set' "another device's configuration never points Howdy at this camera"
pass "another device's installed configuration does not satisfy this camera"

# A failed capture, and a decode that produces no frames, are inconclusive: they
# say why, and they leave a positionally-picked node unconfirmed rather than
# guessing in either direction.
desktop_host
printf 'fail\n' >"$host/ffmpeg.mode"
run_installer
expect_rc0 'capture failure'
expect_out 'ffmpeg: cannot open the capture device' 'a failed capture prints why'
expect_kept_record 'capture failure'
expect_calls 0 'howdy set' 'a failed capture never points Howdy at the node'
desktop_host
printf 'empty\n' >"$host/ffmpeg.mode"
run_installer
expect_rc0 'empty decode'
expect_out 'no frames' 'a decode with no frames prints why'
expect_kept_record 'empty decode'
pass 'a failed capture and an empty decode are inconclusive, print why, and confirm nothing'

# =============================================================================
# U4 -- the capture format Howdy reads
# =============================================================================

howdy_value() { sed -n "s/^$1 = //p" "$host/etc/howdy/config.ini"; }

# A greyscale node leaves the MJPEG option alone.
thinkpad_host
run_installer
expect_rc0 'U4 greyscale'
expect_calls 0 'howdy set force_mjpeg' 'U4 a greyscale node never writes the MJPEG option'
[[ "$(howdy_value force_mjpeg)" == false ]] || fail 'U4: the MJPEG option moved on a greyscale node'
pass 'U4: a greyscale node issues no MJPEG option write'

# ...even when the operator already set it.
thinkpad_host
printf '[video]\ndevice_path = none\nforce_mjpeg = true\n' >"$host/etc/howdy/config.ini"
run_installer
expect_rc0 'U4 greyscale with the option set'
expect_calls 0 'howdy set force_mjpeg' 'U4 an existing MJPEG option is left untouched on a greyscale node'
[[ "$(howdy_value force_mjpeg)" == true ]] || fail 'U4: the installer rewrote an operator-set MJPEG option'
pass 'U4: an MJPEG option already set is left alone on a greyscale node'

# A node with no greyscale format asserts the option once, and a second run
# writes nothing at all.
desktop_host
run_installer
expect_rc0 'U4 non-greyscale first run'
expect_calls 1 'howdy set force_mjpeg true' 'U4 a non-greyscale node asserts the MJPEG option'
expect_calls 1 "howdy set device_path $host/dev/v4l/by-path/$desktop_by_path" 'U4 the device path is written once'
[[ "$(howdy_value force_mjpeg)" == true ]] || fail 'U4: the MJPEG option is not set after the first run'
run_installer
expect_rc0 'U4 non-greyscale second run'
expect_calls 1 'howdy set force_mjpeg true' 'U4 the second run writes no second MJPEG option'
expect_calls 1 'howdy set device_path' 'U4 an unchanged device path issues no howdy set'
expect_calls 2 'howdy set' 'U4 the whole apply performed exactly two Howdy writes across two runs'
pass 'U4: the MJPEG option and the device path are each written once across two runs'

# A host where no node resolved writes neither.
desktop_host
for node in video0 video1 video2 video3; do : >"$host/v4l2/$node"; done
cp "$host/etc/howdy/config.ini" "$host/config.before"
run_installer
expect_rc0 'U4 no node'
expect_calls 0 'howdy set' 'U4 a host with no node writes neither option'
cmp -s "$host/etc/howdy/config.ini" "$host/config.before" || fail 'U4: /etc/howdy/config.ini changed although no node resolved'
pass 'U4: a host with no resolved node leaves the Howdy config untouched'

printf '%s: PASS\n' "$prog"
