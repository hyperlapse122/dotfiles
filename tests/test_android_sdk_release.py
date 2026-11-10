"""Drive the Ruby android-sdk-release against a fake repository2-3.xml.

The helper's `curl` command is stubbed on `PATH` so these tests serve a
fixture repository instead. The fixture holds a stable and a preview
release of each tracked package, an obsolete duplicate revision, and a
`;latest` alias, which are the cases the selection rules have to tell apart.
A second fixture stands in for the Google APIs system image XML, served for
any URL under sys-img/; it lists both the arm64-v8a and x86_64 image of each
platform.
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

# The flake check points ANDROID_SDK_RELEASE at the packaged helper; run
# directly, the tests drive the script with whatever ruby is on PATH.
SCRIPT = Path(__file__).resolve().parents[1] / "scripts/android-sdk-release"
COMMAND = (
    [os.environ["ANDROID_SDK_RELEASE"]]
    if os.environ.get("ANDROID_SDK_RELEASE")
    else ["ruby", str(SCRIPT)]
)


def generic(path, major, minor, micro, url, sha1, channel="channel-0", license_ref="android-sdk-license", host_os="linux"):
    host = f"<host-os>{host_os}</host-os>" if host_os else ""
    return f"""
  <remotePackage path="{path}">
    <type-details xsi:type="generic:genericDetailsType"/>
    <revision><major>{major}</major><minor>{minor}</minor><micro>{micro}</micro></revision>
    <display-name>{path} display</display-name>
    <uses-license ref="{license_ref}"/>
    <channelRef ref="{channel}"/>
    <archives>
      <archive>
        <complete><size>10</size><checksum type="sha1">{sha1}</checksum><url>{url}</url></complete>
        {host}
      </archive>
    </archives>
  </remotePackage>"""


def platform(api, major, url, sha1, obsolete=False):
    flag = ' obsolete="true"' if obsolete else ""
    return f"""
  <remotePackage path="platforms;android-{api}"{flag}>
    <type-details xsi:type="sdk:platformDetailsType">
      <api-level>{api}</api-level>
      <layoutlib api="15"/>
    </type-details>
    <revision><major>{major}</major></revision>
    <display-name>Android SDK Platform {api}</display-name>
    <uses-license ref="android-sdk-license"/>
    <channelRef ref="channel-0"/>
    <archives>
      <archive>
        <complete><size>20</size><checksum type="sha1">{sha1}</checksum><url>{url}</url></complete>
      </archive>
    </archives>
  </remotePackage>"""


def image(api, abi, major, url, sha1, license_ref="android-sdk-license", emulator_min=35):
    return f"""
  <remotePackage path="system-images;android-{api};google_apis;{abi}">
    <type-details xsi:type="sys-img:sysImgDetailsType">
      <api-level>{api}</api-level>
      <tag><id>google_apis</id><display>Google APIs</display></tag>
      <vendor><id>google</id><display>Google Inc.</display></vendor>
      <abi>{abi}</abi>
    </type-details>
    <revision><major>{major}</major></revision>
    <display-name>Google APIs {abi} System Image</display-name>
    <uses-license ref="{license_ref}"/>
    <dependencies>
      <dependency path="emulator"><min-revision><major>{emulator_min}</major></min-revision></dependency>
    </dependencies>
    <channelRef ref="channel-0"/>
    <archives>
      <archive>
        <complete><size>30</size><checksum type="sha1">{sha1}</checksum><url>{url}</url></complete>
      </archive>
    </archives>
  </remotePackage>"""


def images(*packages):
    return f"""<?xml version="1.0" encoding="utf-8"?>
<sys-img:sdk-sys-img xmlns:sys-img="http://schemas.android.com/sdk/android/repo/sys-img2/03"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <license id="android-sdk-license" type="text">Terms
and Conditions

Second  paragraph.</license>
  <license id="android-sdk-arm-dbt-license" type="text">ARM terms</license>
  <channel id="channel-0">stable</channel>
{''.join(packages)}
</sys-img:sdk-sys-img>
"""


def repository(*packages):
    return f"""<?xml version="1.0" encoding="utf-8"?>
<sdk:sdk-repository xmlns:sdk="http://schemas.android.com/sdk/android/repo/repository2/03"
    xmlns:generic="http://schemas.android.com/repository/android/generic/02"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <license id="android-sdk-license" type="text">Terms
and Conditions

Second  paragraph.</license>
  <license id="android-sdk-preview-license" type="text">Preview terms</license>
  <channel id="channel-0">stable</channel>
  <channel id="channel-1">beta</channel>
{''.join(packages)}
</sdk:sdk-repository>
"""


BASE = [
    generic("cmdline-tools;22.0", 22, 0, "", "cmdline-22.zip", "c22"),
    generic("cmdline-tools;23.0", 23, 0, "", "cmdline-23.zip", "c23"),
    generic("cmdline-tools;24.0", 24, 0, "", "cmdline-24.zip", "c24", channel="channel-1"),
    generic("cmdline-tools;latest", 99, 0, "", "cmdline-latest.zip", "cl"),
    generic("platform-tools", 37, 0, 1, "platform-tools_r37.0.1-linux.zip", "p3701"),
    generic("emulator", 37, 1, 11, "emulator-linux_x64-37.1.11.zip", "e37111"),
    generic("emulator", 37, 2, 4, "emulator-linux_x64-37.2.4.zip", "e3724", channel="channel-1"),
    generic("build-tools;36.0.0", 36, 0, 0, "build-tools_r36_linux.zip", "b36"),
    generic("build-tools;37.0.0", 37, 0, 0, "build-tools_r37_linux.zip", "b37"),
    generic("cmake;3.22.1", 3, 22, 1, "cmake-3.22.1-linux.zip", "m3221"),
    generic("cmake;4.1.2", 4, 1, 2, "cmake-4.1.2-linux.zip", "m412"),
    generic("ndk;29.0.14206865", 29, 0, 14206865, "android-ndk-r29-linux.zip", "n29"),
    generic("ndk;30.0.15729638", 30, 0, 15729638, "android-ndk-r30-linux.zip", "n30", channel="channel-1"),
    platform(36, 2, "platform-36_r02.zip", "a36"),
    platform("37.0", 2, "platform-37.0_r02.zip", "a370"),
    platform(34, 2, "platform-34_r02.zip", "a34r2"),
    platform(34, 3, "platform-34_r03.zip", "a34r3", obsolete=True),
]

IMAGES = [
    image(36, "x86_64", 7, "x86_64-36_r07.zip", "i36x"),
    image("37.0", "x86_64", 6, "x86_64-37.0_r06.zip", "i370x"),
    image(36, "arm64-v8a", 7, "arm64-v8a-36_r07.zip", "i36a", license_ref="android-sdk-arm-dbt-license"),
    image("37.0", "arm64-v8a", 6, "arm64-v8a-37.0_r06.zip", "i370a", license_ref="android-sdk-arm-dbt-license"),
    image(34, "x86_64", 14, "x86_64-34_r14.zip", "i34x"),
    image(34, "arm64-v8a", 14, "arm64-v8a-34_r14.zip", "i34a", license_ref="android-sdk-arm-dbt-license"),
    image(33, "x86_64", 9, "x86_64-33_r09.zip", "i33x"),
]

IMAGE_URL = "https://dl.google.com/android/repository/sys-img/google_apis/sys-img2-3.xml"

FAKE_CURL = """#!{python}
import os, sys
if sys.argv[1:4] != ['-sfL', '--max-time', '60'] or len(sys.argv) != 5:
    sys.stderr.write(f'unexpected curl argv: {{sys.argv[1:]!r}}\\n')
    sys.exit(99)
url = sys.argv[4]
with open(os.environ['FAKE_LOG'], 'a') as log:
    log.write(url + '\\n')
kind = 'IMAGE' if '/sys-img/' in url else 'REPO'
status = int(os.environ.get('FAKE_' + kind + '_STATUS', '0'))
if status:
    sys.exit(status)
sys.stdout.write(os.environ['FAKE_' + kind + '_BODY'])
"""


class AndroidSdkReleaseTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.bin_dir = root / "bin"
        self.bin_dir.mkdir()
        curl = self.bin_dir / "curl"
        curl.write_text(FAKE_CURL.format(python=sys.executable))
        curl.chmod(0o755)
        self.output = root / "android-sdk-repo.json"
        self.log = root / "fetched"

    def run_release(self, args, body=None, status=0, image_body=None, image_status=0):
        env = dict(os.environ)
        env["PATH"] = f"{self.bin_dir}:{env.get('PATH', '')}"
        env["FAKE_LOG"] = str(self.log)
        env["FAKE_REPO_BODY"] = repository(*BASE) if body is None else body
        env["FAKE_REPO_STATUS"] = str(status)
        env["FAKE_IMAGE_BODY"] = images(*IMAGES) if image_body is None else image_body
        env["FAKE_IMAGE_STATUS"] = str(image_status)
        return subprocess.run(
            [*COMMAND, *args], capture_output=True, text=True, env=env
        )

    def write_pin(self, *extra):
        result = self.run_release(
            ["-o", str(self.output), "--build-tools", "36.0.0", "--cmake", "3.22.1", "--ndk", "29.0.14206865",
             "--platforms", "36", *extra]
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(self.output.read_text())

    def test_tracks_newest_stable_and_keeps_declared_versions(self):
        pin = self.write_pin()
        self.assertEqual(
            pin["latest"],
            {
                "cmdline-tools": "23.0",
                "emulator": "37.1.11",
                "platform-tools": "37.0.1",
                "build-tools": "36.0.0",
                "cmake": "3.22.1",
                "ndk": "29.0.14206865",
                "platforms": "36",
            },
        )
        self.assertEqual(sorted(pin["packages"]["cmdline-tools"]), ["23.0"])
        self.assertEqual(sorted(pin["packages"]["emulator"]), ["37.1.11"])
        self.assertEqual(sorted(pin["packages"]["build-tools"]), ["36.0.0"])
        self.assertEqual(sorted(pin["packages"]["cmake"]), ["3.22.1"])
        self.assertEqual(sorted(pin["packages"]["ndk"]), ["29.0.14206865"])
        self.assertEqual(sorted(pin["packages"]["platforms"]), ["36"])

    def test_renders_androidenv_entries(self):
        pin = self.write_pin()
        tools = pin["packages"]["platform-tools"]["37.0.1"]
        self.assertEqual(tools["path"], "platform-tools")
        self.assertEqual(tools["name"], "platform-tools")
        self.assertEqual(tools["license"], "android-sdk-license")
        self.assertEqual(tools["revision-details"], {"major:0": "37", "minor:1": "0", "micro:2": "1"})
        self.assertEqual(
            tools["type-details"], {"element-attributes": {"xsi:type": "ns5:genericDetailsType"}}
        )
        self.assertEqual(
            tools["archives"],
            [
                {
                    "arch": "all",
                    "os": "linux",
                    "sha1": "p3701",
                    "size": 10,
                    "url": "https://dl.google.com/android/repository/platform-tools_r37.0.1-linux.zip",
                }
            ],
        )
        platform36 = pin["packages"]["platforms"]["36"]
        self.assertEqual(platform36["path"], "platforms/android-36")
        self.assertEqual(
            platform36["type-details"],
            {
                "api-level:0": "36",
                "layoutlib:1": {"element-attributes": {"api": "15"}},
                "element-attributes": {"xsi:type": "ns11:platformDetailsType"},
            },
        )
        self.assertEqual(platform36["archives"][0]["os"], "all")

    def test_renders_the_declared_ndk_at_its_side_by_side_path(self):
        pin = self.write_pin()
        ndk = pin["packages"]["ndk"]["29.0.14206865"]
        self.assertEqual(ndk["name"], "ndk")
        self.assertEqual(ndk["path"], "ndk/29.0.14206865")
        self.assertEqual(ndk["revision"], "29.0.14206865")
        self.assertEqual(ndk["archives"][0]["sha1"], "n29")

    def test_later_run_keeps_the_declared_ndk_despite_a_newer_one(self):
        self.write_pin()
        newer = BASE + [
            generic("ndk;31.0.1", 31, 0, 1, "android-ndk-r31-linux.zip", "n31")
        ]
        result = self.run_release(["-o", str(self.output)], body=repository(*newer))
        self.assertEqual(result.returncode, 0, result.stderr)
        pin = json.loads(self.output.read_text())
        self.assertEqual(sorted(pin["packages"]["ndk"]), ["29.0.14206865"])

    def test_renders_the_declared_cmake_at_its_versioned_path(self):
        pin = self.write_pin()
        cmake = pin["packages"]["cmake"]["3.22.1"]
        self.assertEqual(cmake["path"], "cmake/3.22.1")
        self.assertEqual(cmake["revision"], "3.22.1")
        self.assertEqual(cmake["archives"][0]["sha1"], "m3221")

    def test_requires_a_cmake_for_a_new_pin(self):
        result = self.run_release(
            ["-o", str(self.output), "--build-tools", "36.0.0", "--ndk", "29.0.14206865",
             "--platforms", "36"]
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("pass --cmake", result.stderr)
        self.assertFalse(self.output.exists())

    def test_requires_an_ndk_for_a_new_pin(self):
        result = self.run_release(
            ["-o", str(self.output), "--build-tools", "36.0.0", "--cmake", "3.22.1",
             "--platforms", "36"]
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("pass --ndk", result.stderr)
        self.assertFalse(self.output.exists())

    def test_pins_the_arm64_and_x86_64_google_apis_images_of_each_declared_platform(self):
        pin = self.write_pin()
        self.assertEqual(list(pin["images"]), ["36"])
        self.assertEqual(list(pin["images"]["36"]), ["google_apis"])
        self.assertEqual(list(pin["images"]["36"]["google_apis"]), ["arm64-v8a", "x86_64"])
        entry = pin["images"]["36"]["google_apis"]["x86_64"]
        self.assertEqual(entry["name"], "system-image-36-google_apis-x86_64")
        self.assertEqual(entry["path"], "system-images/android-36/google_apis/x86_64")
        self.assertEqual(entry["revision"], "36-google_apis-x86_64")
        self.assertEqual(entry["license"], "android-sdk-license")
        self.assertEqual(entry["revision-details"], {"major:0": "7"})
        self.assertEqual(entry["type-details"]["abi:3"], "x86_64")
        self.assertEqual(
            entry["dependencies"]["dependency:0"]["element-attributes"], {"path": "emulator"}
        )
        self.assertNotIn("last-available-day", entry)
        self.assertEqual(
            entry["archives"],
            [
                {
                    "arch": "all",
                    "os": "all",
                    "sha1": "i36x",
                    "size": 30,
                    "url": "https://dl.google.com/android/repository/sys-img/google_apis/x86_64-36_r07.zip",
                }
            ],
        )
        self.assertIn(IMAGE_URL, self.log.read_text().split())

    def test_pins_the_arm64_v8a_image_beside_the_x86_64_one(self):
        pin = self.write_pin()
        entry = pin["images"]["36"]["google_apis"]["arm64-v8a"]
        self.assertEqual(entry["name"], "system-image-36-google_apis-arm64-v8a")
        self.assertEqual(entry["path"], "system-images/android-36/google_apis/arm64-v8a")
        self.assertEqual(entry["license"], "android-sdk-arm-dbt-license")
        self.assertEqual(entry["type-details"]["abi:3"], "arm64-v8a")
        self.assertEqual(
            entry["archives"][0]["url"],
            "https://dl.google.com/android/repository/sys-img/google_apis/arm64-v8a-36_r07.zip",
        )

    def test_image_follows_a_second_declared_platform(self):
        pin = self.write_pin("--platforms", "34")
        self.assertEqual(sorted(pin["images"]), ["34", "36"])
        self.assertEqual(sorted(pin["images"]["34"]["google_apis"]), ["arm64-v8a", "x86_64"])
        self.assertEqual(pin["images"]["34"]["google_apis"]["x86_64"]["archives"][0]["sha1"], "i34x")
        self.assertEqual(pin["images"]["34"]["google_apis"]["arm64-v8a"]["archives"][0]["sha1"], "i34a")

    def test_pins_a_minor_level_platform_beside_a_major_one(self):
        # API 37 ships only as platforms;android-37.0, keyed "37.0".
        pin = self.write_pin("--platforms", "37.0")
        self.assertEqual(sorted(pin["packages"]["platforms"]), ["36", "37.0"])
        self.assertEqual(pin["packages"]["platforms"]["37.0"]["path"], "platforms/android-37.0")
        self.assertEqual(sorted(pin["images"]), ["36", "37.0"])
        self.assertEqual(sorted(pin["images"]["37.0"]["google_apis"]), ["arm64-v8a", "x86_64"])
        self.assertEqual(
            pin["images"]["37.0"]["google_apis"]["x86_64"]["path"],
            "system-images/android-37.0/google_apis/x86_64",
        )
        self.assertEqual(
            pin["images"]["37.0"]["google_apis"]["arm64-v8a"]["path"],
            "system-images/android-37.0/google_apis/arm64-v8a",
        )
        self.assertEqual(pin["latest"]["platforms"], "37.0")

        result = self.run_release(["-o", str(self.output)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("already up to date", result.stdout)
        self.assertEqual(sorted(json.loads(self.output.read_text())["images"]), ["36", "37.0"])

    def test_image_url_follows_the_repository_url(self):
        result = self.run_release(
            ["--dry-run", "--url", "https://mirror.test/repo/repository2-3.xml",
             "--build-tools", "36.0.0", "--cmake", "3.22.1", "--ndk", "29.0.14206865", "--platforms", "36"]
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "https://mirror.test/repo/sys-img/google_apis/sys-img2-3.xml", self.log.read_text().split()
        )

    def test_refuses_a_declared_platform_without_an_image(self):
        without = [p for p in IMAGES if "android-36;google_apis;x86_64" not in p]
        result = self.run_release(
            ["-o", str(self.output), "--build-tools", "36.0.0", "--cmake", "3.22.1", "--ndk", "29.0.14206865",
             "--platforms", "36"],
            image_body=images(*without),
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("no google_apis x86_64 system image for platform 36", result.stderr)
        self.assertFalse(self.output.exists())

    def test_refuses_a_declared_platform_without_an_arm64_image(self):
        # API 33 lists only its x86_64 image.
        result = self.run_release(
            ["-o", str(self.output), "--build-tools", "36.0.0", "--cmake", "3.22.1", "--ndk", "29.0.14206865",
             "--platforms", "36", "--platforms", "33"],
            body=repository(*BASE, platform(33, 3, "platform-33_r03.zip", "a33")),
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("no google_apis arm64-v8a system image for platform 33", result.stderr)
        self.assertFalse(self.output.exists())

    def test_refuses_to_downgrade_the_emulator(self):
        self.write_pin()
        before = self.output.read_text()
        older = [p for p in BASE if '"emulator"' not in p] + [
            generic("emulator", 36, 0, 0, "emulator-36.zip", "e36")
        ]
        result = self.run_release(["-o", str(self.output)], body=repository(*older))
        self.assertEqual(result.returncode, 1)
        self.assertIn("newest stable emulator 36.0.0 is older", result.stderr)
        self.assertEqual(self.output.read_text(), before)

    def test_refuses_an_image_that_needs_a_newer_emulator(self):
        needy = [p for p in IMAGES if "android-36;google_apis;x86_64" not in p] + [
            image(36, "x86_64", 8, "x86_64-36_r08.zip", "i36x8", emulator_min=38)
        ]
        result = self.run_release(
            ["-o", str(self.output), "--build-tools", "36.0.0", "--cmake", "3.22.1", "--ndk", "29.0.14206865",
             "--platforms", "36"],
            image_body=images(*needy),
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("needs emulator 38 or newer, but the pinned emulator is 37.1.11", result.stderr)
        self.assertFalse(self.output.exists())

    def test_refuses_an_arm64_image_that_needs_a_newer_emulator(self):
        needy = [p for p in IMAGES if "android-36;google_apis;arm64-v8a" not in p] + [
            image(36, "arm64-v8a", 8, "arm64-v8a-36_r08.zip", "i36a8",
                  license_ref="android-sdk-arm-dbt-license", emulator_min=38)
        ]
        result = self.run_release(
            ["-o", str(self.output), "--build-tools", "36.0.0", "--cmake", "3.22.1", "--ndk", "29.0.14206865",
             "--platforms", "36"],
            image_body=images(*needy),
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn(
            "system image 36 google_apis arm64-v8a needs emulator 38 or newer, but the pinned emulator is 37.1.11",
            result.stderr,
        )
        self.assertFalse(self.output.exists())

    def test_bumps_an_image_when_upstream_moves(self):
        self.write_pin()
        newer = [p for p in IMAGES if "android-36;google_apis;x86_64" not in p] + [
            image(36, "x86_64", 8, "x86_64-36_r08.zip", "i36x8")
        ]
        result = self.run_release(["-o", str(self.output)], image_body=images(*newer))
        self.assertEqual(result.returncode, 0, result.stderr)
        entry = json.loads(self.output.read_text())["images"]["36"]["google_apis"]["x86_64"]
        self.assertEqual(entry["archives"][0]["sha1"], "i36x8")

    def test_refuses_to_downgrade_an_image(self):
        self.write_pin()
        before = self.output.read_text()
        older = [p for p in IMAGES if "android-36;google_apis;x86_64" not in p] + [
            image(36, "x86_64", 6, "x86_64-36_r06.zip", "i36x6")
        ]
        result = self.run_release(["-o", str(self.output)], image_body=images(*older))
        self.assertEqual(result.returncode, 1)
        self.assertIn("system image 36 google_apis x86_64 revision 6 is older than the pinned 7", result.stderr)
        self.assertEqual(self.output.read_text(), before)

    def test_refuses_to_downgrade_an_arm64_image_while_x86_64_moves_up(self):
        self.write_pin()
        before = self.output.read_text()
        moved = [p for p in IMAGES if "android-36;google_apis;" not in p] + [
            image(36, "x86_64", 8, "x86_64-36_r08.zip", "i36x8"),
            image(36, "arm64-v8a", 6, "arm64-v8a-36_r06.zip", "i36a6", license_ref="android-sdk-arm-dbt-license"),
        ]
        result = self.run_release(["-o", str(self.output)], image_body=images(*moved))
        self.assertEqual(result.returncode, 1)
        self.assertIn("system image 36 google_apis arm64-v8a revision 6 is older than the pinned 7", result.stderr)
        self.assertEqual(self.output.read_text(), before)

    def test_image_fetch_failure_writes_nothing(self):
        result = self.run_release(
            ["-o", str(self.output), "--build-tools", "36.0.0", "--cmake", "3.22.1", "--ndk", "29.0.14206865",
             "--platforms", "36"], image_status=22
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("sys-img2-3.xml failed with status 22", result.stderr)
        self.assertFalse(self.output.exists())

    def test_malformed_image_xml_is_refused(self):
        result = self.run_release(
            ["--dry-run", "--build-tools", "36.0.0", "--cmake", "3.22.1", "--ndk", "29.0.14206865", "--platforms", "36"], image_body="<not-xml"
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("system image XML did not parse", result.stderr)

    def test_keeps_only_referenced_licenses_normalized(self):
        pin = self.write_pin()
        self.assertEqual(
            pin["licenses"],
            {
                "android-sdk-arm-dbt-license": ["ARM terms"],
                "android-sdk-license": ["Terms and Conditions\n\nSecond paragraph."],
            },
        )

    def test_duplicate_revision_fills_obsolete_and_merges_archives(self):
        pin = self.write_pin("--platforms", "34")
        platform34 = pin["packages"]["platforms"]["34"]
        self.assertEqual(platform34["obsolete"], "true")
        self.assertEqual(platform34["revision-details"], {"major:0": "2"})
        self.assertEqual([a["sha1"] for a in platform34["archives"]], ["a34r3"])

    def test_later_run_keeps_declared_versions_from_the_pin(self):
        self.write_pin("--build-tools", "37.0.0")
        result = self.run_release(["-o", str(self.output)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("already up to date", result.stdout)
        pin = json.loads(self.output.read_text())
        self.assertEqual(sorted(pin["packages"]["build-tools"]), ["36.0.0", "37.0.0"])
        self.assertEqual(pin["latest"]["build-tools"], "37.0.0")

    def test_bumps_a_tracked_package_when_upstream_moves(self):
        self.write_pin()
        newer = [p for p in BASE if "platform-tools" not in p] + [
            generic("platform-tools", 37, 0, 2, "platform-tools_r37.0.2-linux.zip", "p3702")
        ]
        result = self.run_release(["-o", str(self.output)], body=repository(*newer))
        self.assertEqual(result.returncode, 0, result.stderr)
        pin = json.loads(self.output.read_text())
        self.assertEqual(sorted(pin["packages"]["platform-tools"]), ["37.0.2"])
        self.assertEqual(pin["packages"]["platforms"]["36"]["archives"][0]["sha1"], "a36")

    def test_ignores_preview_licensed_release_on_stable_channel(self):
        extra = generic(
            "cmdline-tools;25.0", 25, 0, "", "cmdline-25.zip", "c25",
            license_ref="android-sdk-preview-license",
        )
        result = self.run_release(
            ["--dry-run", "--build-tools", "36.0.0", "--cmake", "3.22.1", "--ndk", "29.0.14206865", "--platforms", "36"],
            body=repository(*BASE, extra),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["latest"]["cmdline-tools"], "23.0")

    def test_refuses_to_downgrade_a_tracked_package(self):
        self.write_pin()
        before = self.output.read_text()
        older = [p for p in BASE if "platform-tools" not in p] + [
            generic("platform-tools", 36, 0, 0, "platform-tools_r36-linux.zip", "p36")
        ]
        result = self.run_release(["-o", str(self.output)], body=repository(*older))
        self.assertEqual(result.returncode, 1)
        self.assertIn("refusing to downgrade", result.stderr)
        self.assertEqual(self.output.read_text(), before)

    def test_refuses_to_drop_a_declared_version(self):
        self.write_pin()
        before = self.output.read_text()
        without = [p for p in BASE if "build-tools;36.0.0" not in p]
        result = self.run_release(["-o", str(self.output)], body=repository(*without))
        self.assertEqual(result.returncode, 1)
        self.assertIn("build-tools 36.0.0 is not in the upstream repository", result.stderr)
        self.assertEqual(self.output.read_text(), before)

    def test_requires_declared_versions_for_a_new_pin(self):
        result = self.run_release(["-o", str(self.output)])
        self.assertEqual(result.returncode, 1)
        self.assertIn("pass --build-tools", result.stderr)
        self.assertFalse(self.output.exists())

    def test_fetch_failure_writes_nothing(self):
        result = self.run_release(["-o", str(self.output)], status=22)
        self.assertEqual(result.returncode, 1)
        self.assertIn("failed with status 22", result.stderr)
        self.assertFalse(self.output.exists())

    def test_malformed_xml_is_refused(self):
        result = self.run_release(["--dry-run"], body="<not-xml")
        self.assertEqual(result.returncode, 1)
        self.assertIn("did not parse", result.stderr)


if __name__ == "__main__":
    unittest.main()
