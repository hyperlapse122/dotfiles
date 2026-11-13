import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path


def version(value):
    return tuple(map(int, value.split(".")[:3]))


entries = json.loads(Path(sys.argv[1]).read_text())
assert entries and {entry["bootstrap"] for entry in entries} == {False, True}, "Flutter coverage needs production and bootstrap profiles"
darwin = sys.platform == "darwin"
versions = set()
for entry in entries:
    name = entry["name"]
    assert entry["profile"], f"{name}: missing user profile"
    profile = Path(entry["profile"])
    assert (profile / "bin/flutter").is_file(), f"{name}: missing Flutter in materialized profile"
    assert (profile / "bin/dart").is_file(), f"{name}: missing bundled Dart in materialized profile"
    assert entry["sdk"], f"{name}: missing Flutter SDK"
    sdk = Path(entry["sdk"])
    with tempfile.TemporaryDirectory() as home:
        env = {
            "HOME": home,
            "PATH": os.environ["PATH"],
            "XDG_CONFIG_HOME": home + "/.config",
            "XDG_CACHE_HOME": home + "/.cache",
            "FLUTTER_SUPPRESS_ANALYTICS": "true",
        }
        reported = json.loads(subprocess.check_output([profile / "bin/flutter", "--version", "--machine"], env=env, text=True))
        dart = subprocess.check_output([profile / "bin/dart", "--version"], env=env, text=True, stderr=subprocess.STDOUT)
    installed = json.loads((sdk / "bin/cache/flutter.version.json").read_text())
    assert reported["frameworkVersion"] == installed["frameworkVersion"], f"{name}: profile reaches another Flutter SDK"
    assert reported["channel"] == "stable" and version(reported["frameworkVersion"]) >= (3, 47, 8), f"{name}: unpatched or unstable Flutter"
    assert version(reported["dartSdkVersion"]) >= (3, 13, 7), f"{name}: unpatched bundled Dart"
    assert f"Dart SDK version: {reported['dartSdkVersion']} " in dart, f"{name}: Dart differs from Flutter's bundled SDK"
    versions.add((reported["frameworkVersion"], reported["dartSdkVersion"]))
    artifacts = [
        "bin/cache/flutter_web_sdk/kernel/dart2js_platform.dill",
        "bin/cache/artifacts/engine/android-arm64/flutter.jar",
    ]
    if darwin:
        artifacts += [
            "bin/cache/artifacts/engine/ios/Flutter.xcframework/Info.plist",
            "bin/cache/artifacts/engine/darwin-x64/FlutterMacOS.xcframework/Info.plist",
        ]
        assert (profile / "bin/pod").is_file(), f"{name}: missing CocoaPods fallback"
    else:
        artifacts += ["bin/cache/artifacts/engine/linux-x64/libflutter_linux_gtk.so"]
    for artifact in artifacts:
        assert (sdk / artifact).is_file(), f"{name}: missing target artifact {artifact}"
    # Check the SDK shipped to users against the template's native prerequisites.
    extension = (sdk / "packages/flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt").read_text()
    compile_sdk = re.search(r"val compileSdkVersion:\s*Int\s*=\s*(\d+)", extension)[1]
    ndk = re.search(r'val ndkVersion:\s*String\s*=\s*"([^"]+)"', extension)[1]
    assert entry["android"], f"{name}: missing managed Android SDK"
    android = Path(entry["android"])
    for prerequisite in (f"platforms/android-{compile_sdk}/android.jar", f"ndk/{ndk}/source.properties"):
        assert (android / prerequisite).is_file(), f"{name}: Flutter template requires {prerequisite}"
    print(f"{name}: Flutter {reported['frameworkVersion']}, Dart {reported['dartSdkVersion']}, target artifacts and Android template prerequisites verified")
assert len(versions) == 1, "Flutter and Dart defaults differ across profiles"
