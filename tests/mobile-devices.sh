#!/usr/bin/env bash
# Usage: bash tests/mobile-devices.sh <mobile-devices executable>
#
# Drives the device helper against a stub xcrun and a stub avdmanager. It
# downloads the newest iOS runtime only when it is missing, creates only the
# declared devices whose versioned names do not exist yet, on the newest
# runtime that supports the model, retries a simctl listing that fails while
# CoreSimulatorService is replaced, keeps devices of an
# older version, a hand-made device, and an undeclared one, skips a platform
# whose tool is missing with one message, reports a device it cannot create or
# a platform step that stops early, and always exits 0. avdmanager runs only
# with the JDK --java-home names. No scenario may delete, erase, rename, or
# move anything.
set -euo pipefail

helper=$1
fail=0
bad() { echo "mobile-devices: $*" >&2; fail=1; }

# State the stubs read and write, under $STUB:
#   sdk        the iOS Simulator SDK versions xcodebuild reports, one per
#              line; a runtime download installs the first
#   no-xcode   present when xcrun cannot find xcodebuild or simctl
#   no-download  present when the runtime download fails
#   bad-types  present when simctl prints a device type list that is not JSON
#   stale-service  present when the loaded CoreSimulatorService predates the
#              installed Xcode: the next simctl call removes it and fails,
#              and the call after it succeeds
#   dead-service  present when every simctl call fails to reach the service
#   bad-runtimes  present when simctl prints a runtime list that is not JSON
#   runtimes   one installed runtime per line: <version>[|<device type id>,...];
#              a runtime without types supports every stub device type
#   sims       one simulator per line: <runtime id>|<name>
#   avds       one AVD name per line
#   calls      every call, its arguments joined with |
#   stdin      what avdmanager create read from stdin
tools=$(mktemp -d)
mkdir -p "$tools/sdk/cmdline-tools/latest/bin" "$tools/no-avdmanager" "$tools/jdk/bin"
# The build sandbox has no /usr/bin/env, so the stubs name this bash.
printf '#!%s\n' "$BASH" > "$tools/xcrun"
cat >> "$tools/xcrun" <<'EOF'
(IFS='|'; echo "xcrun|$*") >> "$STUB/calls"
if [ -e "$STUB/no-xcode" ]; then
  echo "xcrun: error: unable to find utility \"$1\", not a developer tool or in PATH" >&2
  exit 72
fi
runtime_id() { echo "com.apple.CoreSimulator.SimRuntime.iOS-${1//./-}"; }
case "$1 $2" in
  "xcodebuild -showsdks")
    printf '['
    while read -r v; do
      printf '{"platform":"iphoneos","platformVersion":"%s"},' "$v"
      printf '{"platform":"iphonesimulator","platformVersion":"%s"},' "$v"
    done < "$STUB/sdk"
    printf '{"platform":"macosx","platformVersion":"99.0"}]\n'
    ;;
  "xcodebuild -downloadPlatform")
    if [ -e "$STUB/no-download" ]; then
      echo "xcodebuild: error: the download failed" >&2
      exit 70
    fi
    head -n1 "$STUB/sdk" >> "$STUB/runtimes"
    ;;
  "simctl list")
    # Like the real simctl, its last error line has no newline.
    if [ -e "$STUB/dead-service" ] || [ -e "$STUB/stale-service" ]; then
      rm -f "$STUB/stale-service"
      printf 'Error getting a serviceContext: Connection refused' >&2
      exit 1
    fi
    case "$3" in
      runtimes)
        if [ -e "$STUB/bad-runtimes" ]; then
          echo "CoreSimulator is out of date"
          exit 0
        fi
        sep=
        printf '{"runtimes":['
        while IFS='|' read -r v ts; do
          supported=
          for t in ${ts:-iPhone-18 iPhone-18-Pro iPhone-18-Pro-Max iPhone-Duo}; do
            supported+=${supported:+,}'{"identifier":"com.apple.CoreSimulator.SimDeviceType.'$t'"}'
          done
          printf '%s{"platform":"iOS","version":"%s","identifier":"%s","isAvailable":true,"supportedDeviceTypes":[%s]}' \
            "$sep" "$v" "$(runtime_id "$v")" "$supported"
          sep=,
        done < "$STUB/runtimes"
        printf ']}\n'
        ;;
      devicetypes)
        if [ -e "$STUB/bad-types" ]; then
          echo "CoreSimulator is out of date"
          exit 0
        fi
        printf '{"devicetypes":['
        printf '{"name":"iPhone 18","identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-18"},'
        printf '{"name":"iPhone 18 Pro","identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro"},'
        printf '{"name":"iPhone 18 Pro Max","identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro-Max"},'
        printf '{"name":"iPhone Duo","identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-Duo"}'
        printf ']}\n'
        ;;
      devices)
        sep=
        printf '{"devices":{'
        while IFS='|' read -r rt name; do
          printf '%s"%s":[{"name":"%s","udid":"0000","state":"Shutdown"}]' "$sep" "$rt" "$name"
          sep=,
        done < "$STUB/sims"
        printf '}}\n'
        ;;
    esac
    ;;
  "simctl create")
    echo "$5|$3" >> "$STUB/sims"
    echo "1111-2222"
    ;;
esac
EOF
printf '#!%s\n' "$BASH" > "$tools/sdk/cmdline-tools/latest/bin/avdmanager"
cat >> "$tools/sdk/cmdline-tools/latest/bin/avdmanager" <<'EOF'
(IFS='|'; echo "avdmanager|$*") >> "$STUB/calls"
# Like the real start script, it needs $JAVA_HOME/bin/java: with JAVA_HOME
# unset it falls back to `which java`, and activation's PATH has neither
# which nor java. It reports the failure on stdout.
if [ ! -x "${JAVA_HOME:-}/bin/java" ]; then
  echo "ERROR: JAVA_HOME is not set and no 'java' command could be found in your PATH."
  exit 1
fi
case "$1 $2" in
  "list avd") cat "$STUB/avds" ;;
  "create avd")
    cat >> "$STUB/stdin"
    # A device id avdmanager does not know.
    if [ "$8" = broken ]; then
      echo "Error: No device found matching --device broken" >&2
      exit 1
    fi
    echo "$4" >> "$STUB/avds"
    ;;
esac
EOF
printf '#!%s\n' "$BASH" > "$tools/jdk/bin/java"
chmod +x "$tools/xcrun" "$tools/sdk/cmdline-tools/latest/bin/avdmanager" "$tools/jdk/bin/java"

scenario() {
  STUB=$(mktemp -d)
  export STUB
  printf '%s\n' "$1" > "$STUB/sdk"
  touch "$STUB/runtimes" "$STUB/sims" "$STUB/avds" "$STUB/calls" "$STUB/stdin"
}
# Clears the call log and keeps the state, for a second apply.
again() { : > "$STUB/calls"; }
# Runs the helper on the stub tools with JAVA_HOME unset, as activation does.
# A caller points one call at another xcrun, SDK root, or JDK with an xcrun=,
# sdk=, or jdk= prefix, which bash scopes to that call; an empty value keeps
# the stub.
run() {
  local status=0
  env -u JAVA_HOME "$helper" --xcrun "${xcrun:-$tools/xcrun}" --sdk-root "${sdk:-$tools/sdk}" \
    --java-home "${jdk:-$tools/jdk}" "$@" > "$STUB/out" 2> "$STUB/err" || status=$?
  [ "$status" = 0 ] || bad "$label: the helper exited $status: $(cat "$STUB/err")"
}
count() {
  local n
  n=$(grep -cFx "$1" "$STUB/calls") || true
  echo "${n:-0}"
}
creates() {
  local n
  n=$(grep -cE '^(xcrun\|simctl|avdmanager)\|create\|' "$STUB/calls") || true
  echo "${n:-0}"
}
downloads() { count 'xcrun|xcodebuild|-downloadPlatform|iOS'; }
sim_create() { echo "xcrun|simctl|create|$1|com.apple.CoreSimulator.SimDeviceType.${2}|com.apple.CoreSimulator.SimRuntime.iOS-${3//./-}"; }
avd_create() { echo "avdmanager|create|avd|-n|${1}_API_$2|-k|system-images;android-$2;google_apis;arm64-v8a|-d|$1"; }
has_line() { grep -qFx "$1" "$STUB/$2"; }
said() { grep -qF "$1" "$STUB/err"; }
nothing_removed() {
  if grep -qE '\|(delete|erase|rename|move|unpair)(\||$)' "$STUB/calls"; then
    bad "$label: the helper removed or changed a device: $(grep -E '\|(delete|erase|rename|move|unpair)(\||$)' "$STUB/calls")"
  fi
}

label="first apply"
scenario 27.0
run --android-api 37.0 --device "ios:iPhone 18 Pro" --device android:pixel_9
[ "$(downloads)" = 1 ] || bad "$label: the missing iOS 27.0 runtime was downloaded $(downloads) times, not once"
[ "$(count "$(sim_create "iPhone 18 Pro (iOS 27.0)" iPhone-18-Pro 27.0)")" = 1 ] \
  || bad "$label: iPhone 18 Pro (iOS 27.0) was not created once on the iOS 27.0 runtime: $(cat "$STUB/calls")"
[ "$(count "$(avd_create pixel_9 37.0)")" = 1 ] \
  || bad "$label: pixel_9_API_37.0 was not created once from the arm64 37.0 image: $(cat "$STUB/calls")"
[ "$(creates)" = 2 ] || bad "$label: $(creates) devices were created, not 2"
has_line no stdin || bad "$label: avdmanager's custom hardware prompt was not answered no"
nothing_removed

label="second apply"
again
run --android-api 37.0 --device "ios:iPhone 18 Pro" --device android:pixel_9
[ "$(downloads)" = 0 ] || bad "$label: an installed runtime was downloaded again"
[ "$(creates)" = 0 ] || bad "$label: existing devices were created again: $(cat "$STUB/calls")"
nothing_removed

label="newer versions"
scenario 27.1
echo 27.0 > "$STUB/runtimes"
echo "com.apple.CoreSimulator.SimRuntime.iOS-27-0|iPhone 18 Pro (iOS 27.0)" > "$STUB/sims"
echo pixel_9_API_36.0 > "$STUB/avds"
run --android-api 37.0 --device "ios:iPhone 18 Pro" --device android:pixel_9
[ "$(downloads)" = 1 ] || bad "$label: the iOS 27.1 runtime was downloaded $(downloads) times, not once"
[ "$(count "$(sim_create "iPhone 18 Pro (iOS 27.1)" iPhone-18-Pro 27.1)")" = 1 ] \
  || bad "$label: iPhone 18 Pro (iOS 27.1) was not created on the iOS 27.1 runtime: $(cat "$STUB/calls")"
[ "$(count "$(avd_create pixel_9 37.0)")" = 1 ] || bad "$label: pixel_9_API_37.0 was not created beside pixel_9_API_36.0"
has_line "com.apple.CoreSimulator.SimRuntime.iOS-27-0|iPhone 18 Pro (iOS 27.0)" sims || bad "$label: the iOS 27.0 device is gone"
has_line 27.0 runtimes || bad "$label: the iOS 27.0 runtime is gone"
has_line pixel_9_API_36.0 avds || bad "$label: pixel_9_API_36.0 is gone"
nothing_removed

label="undeclared devices"
scenario 27.0
echo 27.0 > "$STUB/runtimes"
echo "com.apple.CoreSimulator.SimRuntime.iOS-27-0|My Hand-Made Phone" > "$STUB/sims"
printf '%s\n' pixel_8_API_37.0 pixel_9_API_37.0 > "$STUB/avds"
run --android-api 37.0 --device "ios:iPhone 18 Pro" --device android:pixel_9
[ "$(count "$(sim_create "iPhone 18 Pro (iOS 27.0)" iPhone-18-Pro 27.0)")" = 1 ] || bad "$label: the declared iPhone was not created"
[ "$(downloads)" = 0 ] || bad "$label: the installed iOS 27.0 runtime was downloaded again"
[ "$(creates)" = 1 ] || bad "$label: $(creates) devices were created, not 1"
has_line "com.apple.CoreSimulator.SimRuntime.iOS-27-0|My Hand-Made Phone" sims || bad "$label: the hand-made simulator is gone"
has_line pixel_8_API_37.0 avds || bad "$label: the undeclared AVD is gone"
nothing_removed

for broken_xcode in failing missing; do
  label="no Xcode, xcrun $broken_xcode"
  scenario 27.0
  other_xcrun=
  if [ "$broken_xcode" = failing ]; then touch "$STUB/no-xcode"; else other_xcrun=$STUB/no-such-xcrun; fi
  xcrun=$other_xcrun run --android-api 37.0 --device "ios:iPhone 18 Pro" --device android:pixel_9
  [ "$(count "$(avd_create pixel_9 37.0)")" = 1 ] || bad "$label: the Android device was not created"
  [ "$(creates)" = 1 ] || bad "$label: $(creates) devices were created, not 1"
  said "App Store" || bad "$label: the message does not name the App Store sign-in: $(cat "$STUB/err")"
  [ "$(grep -c 'App Store' "$STUB/err")" = 1 ] || bad "$label: the sign-in message was printed $(grep -c "App Store" "$STUB/err") times, not once"
  nothing_removed
done

label="no avdmanager"
scenario 27.0
sdk=$tools/no-avdmanager run --android-api 37.0 \
  --device "ios:iPhone 18 Pro" --device android:pixel_9 --device android:pixel_8
[ "$(count "$(sim_create "iPhone 18 Pro (iOS 27.0)" iPhone-18-Pro 27.0)")" = 1 ] || bad "$label: the iOS device was not created"
said avdmanager || bad "$label: the message does not name avdmanager: $(cat "$STUB/err")"
[ "$(grep -c avdmanager "$STUB/err")" = 1 ] || bad "$label: the missing avdmanager was reported $(grep -c avdmanager "$STUB/err") times, not once"
nothing_removed

label="a JDK avdmanager cannot run"
scenario 27.0
echo 27.0 > "$STUB/runtimes"
jdk=$tools/no-such-jdk run --android-api 37.0 --device "ios:iPhone 18 Pro" --device android:pixel_9
[ "$(count "$(sim_create "iPhone 18 Pro (iOS 27.0)" iPhone-18-Pro 27.0)")" = 1 ] || bad "$label: the iOS device was not created"
said "avdmanager could not list AVDs, so the Android Virtual Devices were skipped: ERROR: JAVA_HOME is not set" \
  || bad "$label: the failed listing was not reported with avdmanager's own error: $(cat "$STUB/err")"
[ "$(creates)" = 1 ] || bad "$label: $(creates) devices were created, not 1"
nothing_removed

label="unknown model and a failing create"
scenario 27.0
run --android-api 37.0 --device "ios:iPhone 99" --device "ios:iPhone 18 Pro" \
  --device android:broken --device android:pixel_9
said "iPhone 99" || bad "$label: the unknown iOS model was not reported by name: $(cat "$STUB/err")"
said broken_API_37.0 || bad "$label: the failed AVD was not reported by name: $(cat "$STUB/err")"
[ "$(count "$(sim_create "iPhone 18 Pro (iOS 27.0)" iPhone-18-Pro 27.0)")" = 1 ] || bad "$label: the known iPhone was not created"
[ "$(count "$(avd_create pixel_9 37.0)")" = 1 ] || bad "$label: pixel_9 was not created after the failed AVD"
if grep -qF 'iPhone 99' "$STUB/calls"; then bad "$label: the unknown model reached simctl create"; fi
nothing_removed

label="explicit versions"
scenario 27.0
printf '%s\n' 26.0 27.0 > "$STUB/runtimes"
run --android-api 37.0 --device "ios:iPhone 18 Pro:26.0" --device android:pixel_9:36.0
[ "$(count "$(sim_create "iPhone 18 Pro (iOS 26.0)" iPhone-18-Pro 26.0)")" = 1 ] \
  || bad "$label: iPhone 18 Pro (iOS 26.0) was not created on the iOS 26.0 runtime: $(cat "$STUB/calls")"
[ "$(count "$(avd_create pixel_9 36.0)")" = 1 ] || bad "$label: pixel_9_API_36.0 was not created from the 36.0 image"
[ "$(creates)" = 2 ] || bad "$label: $(creates) devices were created, not 2"
nothing_removed

label="a device declared twice"
scenario 27.0
echo 27.0 > "$STUB/runtimes"
run --android-api 37.0 --device "ios:iPhone 18 Pro" --device "ios:iPhone 18 Pro" \
  --device android:pixel_9 --device android:pixel_9
[ "$(count "$(sim_create "iPhone 18 Pro (iOS 27.0)" iPhone-18-Pro 27.0)")" = 1 ] \
  || bad "$label: iPhone 18 Pro (iOS 27.0) was not created exactly once: $(cat "$STUB/calls")"
[ "$(count "$(avd_create pixel_9 37.0)")" = 1 ] \
  || bad "$label: pixel_9_API_37.0 was not created exactly once: $(cat "$STUB/calls")"
[ "$(creates)" = 2 ] || bad "$label: $(creates) devices were created, not 2"
nothing_removed

label="a device type list that is not JSON"
scenario 27.0
echo 27.0 > "$STUB/runtimes"
touch "$STUB/bad-types"
run --android-api 37.0 --device "ios:iPhone 18 Pro" --device android:pixel_9
said "the iOS step stopped early" || bad "$label: the iOS step's failure was not reported: $(cat "$STUB/err")"
[ "$(count "$(avd_create pixel_9 37.0)")" = 1 ] || bad "$label: the Android device was not created after the iOS step failed"
[ "$(creates)" = 1 ] || bad "$label: $(creates) devices were created, not 1"
nothing_removed

# The first simctl call after an Xcode upgrade that ships a newer
# CoreSimulator removes the stale service and fails; the call after it works.
label="a stale CoreSimulatorService after an Xcode upgrade"
scenario 27.0
echo 27.0 > "$STUB/runtimes"
touch "$STUB/stale-service"
run --android-api 37.0 --device "ios:iPhone 18 Pro"
[ "$(count "$(sim_create "iPhone 18 Pro (iOS 27.0)" iPhone-18-Pro 27.0)")" = 1 ] \
  || bad "$label: iPhone 18 Pro (iOS 27.0) was not created after the stale service was replaced: $(cat "$STUB/err")"
if said serviceContext; then bad "$label: the error of the call that replaced the service was shown: $(cat "$STUB/err")"; fi
nothing_removed

label="a CoreSimulatorService that never answers"
scenario 27.0
echo 27.0 > "$STUB/runtimes"
touch "$STUB/dead-service"
run --android-api 37.0 --device "ios:iPhone 18 Pro"
[ "$(count 'xcrun|simctl|list|devicetypes|-j')" = 2 ] \
  || bad "$label: the device type listing was tried $(count 'xcrun|simctl|list|devicetypes|-j') times, not twice"
grep -qx 'mobile-devices: simctl could not list device types, so the iOS Simulators were skipped' "$STUB/err" \
  || bad "$label: the skip was not reported on a line of its own: $(cat "$STUB/err")"
grep -qx 'Error getting a serviceContext: Connection refused' "$STUB/err" \
  || bad "$label: simctl's error was not shown once on a line of its own: $(cat "$STUB/err")"
[ "$(creates)" = 0 ] || bad "$label: $(creates) devices were created"
nothing_removed

# Xcode 27.1's iOS 27.1 runtime supports only the iPhone Duo, so an iPhone 18
# Pro without a version goes on the newest runtime that supports it.
label="a newest runtime that supports only some models"
scenario 27.1
printf '%s\n' 27.0 '27.1|iPhone-Duo' > "$STUB/runtimes"
run --android-api 37.0 --device "ios:iPhone 18 Pro" --device "ios:iPhone Duo"
[ "$(downloads)" = 0 ] || bad "$label: the installed iOS 27.1 runtime was downloaded again"
[ "$(count "$(sim_create "iPhone 18 Pro (iOS 27.0)" iPhone-18-Pro 27.0)")" = 1 ] \
  || bad "$label: iPhone 18 Pro was not created on the iOS 27.0 runtime that supports it: $(cat "$STUB/calls")"
[ "$(count "$(sim_create "iPhone Duo (iOS 27.1)" iPhone-Duo 27.1)")" = 1 ] \
  || bad "$label: iPhone Duo was not created on the iOS 27.1 runtime: $(cat "$STUB/calls")"
[ "$(creates)" = 2 ] || bad "$label: $(creates) devices were created, not 2"
again
run --android-api 37.0 --device "ios:iPhone 18 Pro" --device "ios:iPhone Duo"
[ "$(creates)" = 0 ] || bad "$label: a second apply created devices again: $(cat "$STUB/calls")"
nothing_removed

label="an explicit version whose runtime does not support the model"
scenario 27.1
printf '%s\n' 27.0 '27.1|iPhone-Duo' > "$STUB/runtimes"
run --android-api 37.0 --device "ios:iPhone 18 Pro:27.1"
said "so iPhone 18 Pro (iOS 27.1) was skipped" || bad "$label: the device was not reported as skipped: $(cat "$STUB/err")"
[ "$(creates)" = 0 ] || bad "$label: $(creates) devices were created on a runtime that does not support the model"
nothing_removed

label="a runtime listing that fails"
scenario 27.0
echo 27.0 > "$STUB/runtimes"
touch "$STUB/bad-runtimes"
run --android-api 37.0 --device "ios:iPhone 18 Pro" --device android:pixel_9
[ "$(downloads)" = 0 ] || bad "$label: a failed runtime listing was taken for a missing runtime and downloaded"
said "the iOS step stopped early" || bad "$label: the failed listing did not stop the iOS step: $(cat "$STUB/err")"
[ "$(count "$(avd_create pixel_9 37.0)")" = 1 ] || bad "$label: the Android device was not created after the iOS step failed"
nothing_removed

label="a failed runtime download"
scenario 27.0
touch "$STUB/no-download"
run --android-api 37.0 --device "ios:iPhone 18 Pro" --device "ios:iPhone 18"
[ "$(downloads)" = 1 ] || bad "$label: the runtime download was attempted $(downloads) times, not once"
said "downloading the iOS 27.0 Simulator runtime failed" || bad "$label: the failed download was not reported: $(cat "$STUB/err")"
for name in "iPhone 18 Pro (iOS 27.0)" "iPhone 18 (iOS 27.0)"; do
  said "so $name was skipped" || bad "$label: $name was not reported as skipped: $(cat "$STUB/err")"
done
[ "$(creates)" = 0 ] || bad "$label: $(creates) devices were created with no runtime"
nothing_removed

label="an older iOS version without its runtime"
scenario 27.0
echo 27.0 > "$STUB/runtimes"
run --android-api 37.0 --device "ios:iPhone 18 Pro:26.0"
[ "$(downloads)" = 0 ] || bad "$label: a download was attempted for a version older than the SDK"
said "so iPhone 18 Pro (iOS 26.0) was skipped" || bad "$label: the device was not reported as skipped: $(cat "$STUB/err")"
[ "$(creates)" = 0 ] || bad "$label: $(creates) devices were created with no runtime"
nothing_removed

label="a runtime with a patch level"
scenario 27.0
echo 27.0.1 > "$STUB/runtimes"
run --android-api 37.0 --device "ios:iPhone 18 Pro"
[ "$(downloads)" = 0 ] || bad "$label: the installed iOS 27.0.1 runtime was not taken for the 27.0 SDK, so it was downloaded"
[ "$(count "$(sim_create "iPhone 18 Pro (iOS 27.0)" iPhone-18-Pro 27.0.1)")" = 1 ] \
  || bad "$label: iPhone 18 Pro (iOS 27.0) was not created on the iOS 27.0.1 runtime: $(cat "$STUB/calls")"
nothing_removed

# 27.0 is listed first and sorts before 9.3 as text, so only a numeric
# comparison picks it.
label="more than one iOS Simulator SDK"
scenario 27.0
echo 9.3 >> "$STUB/sdk"
echo 27.0 > "$STUB/runtimes"
run --android-api 37.0 --device "ios:iPhone 18 Pro"
[ "$(count "$(sim_create "iPhone 18 Pro (iOS 27.0)" iPhone-18-Pro 27.0)")" = 1 ] \
  || bad "$label: iPhone 18 Pro (iOS 27.0) was not created from the newest SDK, 27.0: $(cat "$STUB/calls")"
[ "$(creates)" = 1 ] || bad "$label: $(creates) devices were created, not 1"
nothing_removed

[ "$fail" = 0 ] || exit 1
echo "mobile-devices: all scenarios passed"
