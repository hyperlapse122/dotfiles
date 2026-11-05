import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("windows_build_smoke", Path(__file__).with_name("smoke_windows_build_environment.py"))
smoke = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(smoke)


class WindowsBuildSmokeTest(unittest.TestCase):
    def test_elevated_verification_fails_before_discovery_or_builds(self):
        with patch.object(smoke, "is_administrator", return_value=True), \
             patch.object(smoke, "visual_studio") as discover, \
             patch.object(smoke, "mfc_builds") as build, \
             patch.object(smoke.platform, "machine", return_value="AMD64"), \
             patch.object(smoke.os, "name", "nt"), \
             patch.dict(os.environ, {"PROCESSOR_ARCHITEW6432": ""}), \
             patch("sys.argv", ["smoke", "--verify-only"]):
            with self.assertRaisesRegex(RuntimeError, "non-elevated|ordinary terminal"):
                smoke.main()
            discover.assert_not_called()
            build.assert_not_called()

    def test_missing_vswhere_gives_manual_preparation_action(self):
        with tempfile.TemporaryDirectory() as scratch:
            with self.assertRaisesRegex(RuntimeError, "Visual Studio Installer|mise run windows-build"):
                smoke.visual_studio({"PROGRAMFILES(X86)": scratch})

    def test_wrong_channel_and_ambiguous_instances_are_rejected(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            discovery = root / "Microsoft Visual Studio/Installer/vswhere.exe"
            discovery.parent.mkdir(parents=True)
            discovery.touch()
            instance = {"instanceId": "one", "productId": "Microsoft.VisualStudio.Product.BuildTools",
                        "channelId": "VisualStudio.18.Release", "installationVersion": "18.1.0",
                        "installationPath": str(root), "isComplete": True, "isLaunchable": True,
                        "isPrerelease": False}
            import json
            for instances in ([{**instance, "channelId": "VisualStudio.18.Preview"}],
                              [instance, {**instance, "instanceId": "two"}]):
                with self.subTest(instances=instances), patch.object(smoke, "run", return_value=json.dumps(instances)):
                    with self.assertRaisesRegex(RuntimeError, "stable|Multiple|ambiguous"):
                        smoke.visual_studio({"PROGRAMFILES(X86)": scratch})

    def test_language_preflight_requires_both_sdks_frameworks_and_rust_targets(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            env = {"DOTNET_ROOT": str(root / "dotnet"), "CARGO_HOME": str(root / "cargo"),
                   "PROGRAMFILES(X86)": str(root / "program files")}
            assemblies = []
            for framework in ("v4.8", "v4.8.1"):
                for name in ("mscorlib.dll", "PresentationFramework.dll", "PresentationCore.dll", "WindowsBase.dll"):
                    path = Path(env["PROGRAMFILES(X86)"]) / "Reference Assemblies/Microsoft/Framework/.NETFramework" / framework / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.touch()
                    assemblies.append(path)
            sdks = f"8.0.100 [{root / 'dotnet/sdk'}]\n10.0.100 [{root / 'dotnet/sdk'}]"
            targets = "x86_64-pc-windows-msvc\naarch64-pc-windows-msvc"

            def query(arguments, **kwargs):
                if "--list-sdks" in arguments:
                    return sdks
                if "--list-runtimes" in arguments:
                    return ""
                if arguments[1:] == ["target", "list", "--installed", "--toolchain", "stable-x86_64-pc-windows-msvc"]:
                    return targets
                self.fail(f"Unexpected or mutating prerequisite command: {arguments}")

            with patch.object(smoke, "run", side_effect=query):
                self.assertEqual(smoke.preflight_languages(root, env), {8: "8.0.100", 10: "10.0.100"})
                for assembly in assemblies:
                    with self.subTest(missing=assembly):
                        assembly.unlink()
                        with self.assertRaisesRegex(RuntimeError, "targeting assembly"):
                            smoke.preflight_languages(root, env)
                        assembly.touch()
                for missing in ("8.0.100", "10.0.100"):
                    original = sdks
                    sdks = "\n".join(line for line in sdks.splitlines() if not line.startswith(missing))
                    with self.subTest(missing=missing), self.assertRaisesRegex(RuntimeError, "Missing stable .NET SDK"):
                        smoke.preflight_languages(root, env)
                    sdks = original
                for target in targets.splitlines():
                    original = targets
                    targets = "\n".join(line for line in targets.splitlines() if line != target)
                    with self.subTest(missing=target), self.assertRaisesRegex(RuntimeError, target):
                        smoke.preflight_languages(root, env)
                    targets = original

    def test_vcpkg_preflight_rejects_wrong_user_integration(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            env = {"VCPKG_ROOT": str(root / "vcpkg")}

            def query(arguments, **kwargs):
                if arguments[-1] == "version":
                    return "vcpkg fixture"
                if arguments[-1] == "HEAD":
                    return "a" * 40
                if arguments[-1] == "-getProperty:VcpkgRoot":
                    return str(root / "wrong-checkout")
                self.fail(f"Unexpected or mutating prerequisite command: {arguments}")

            with patch.object(smoke, "run", side_effect=query), patch.object(smoke, "latest_toolset", return_value="v145"):
                with self.assertRaisesRegex(RuntimeError, "User-wide MSBuild integration"):
                    smoke.preflight_vcpkg(root, root / "MSBuild/Current/Bin/MSBuild.exe", env)

    def test_mfc_preflight_requires_each_architecture_and_both_sdks(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            vs, sdk = root / "vs", root / "sdk"
            msbuild = vs / "MSBuild/Current/Bin/MSBuild.exe"
            default = vs / "VC/Auxiliary/Build/Microsoft.VCToolsVersion.default.txt"
            default.parent.mkdir(parents=True)
            default.write_text("14.50.1", encoding="utf-8")
            files = []
            for version in ("14.50.1", "14.44.1", "14.29.1"):
                for arch in ("x86", "x64", "arm64"):
                    for suffix in (f"bin/Hostx64/{arch}/cl.exe", "atlmfc/include/afx.h",
                                   f"atlmfc/lib/{arch}/uafxcw.lib"):
                        files.append(vs / "VC/Tools/MSVC" / version / suffix)
            for version in ("10.0.22621.0", "10.0.26100.0"):
                files.append(sdk / f"Include/{version}/um/Windows.h")
                for arch in ("x86", "x64", "arm64"):
                    files.extend((sdk / f"Lib/{version}/um/{arch}/kernel32.lib",
                                  sdk / f"Lib/{version}/ucrt/{arch}/ucrt.lib"))
            files = list(dict.fromkeys(files))
            for path in files:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.touch()

            def query(arguments, **kwargs):
                project = Path(arguments[1]).read_text(encoding="utf-8")
                toolset = next(name for name in ("v145", "v143", "v142") if f"<PlatformToolset>{name}</PlatformToolset>" in project)
                if arguments[-1] == "-getProperty:PlatformToolset":
                    return toolset
                if arguments[-1] == "-getProperty:VCToolsVersion":
                    return {"v145": "14.50.1", "v143": "14.44.1", "v142": "14.29.1"}[toolset]
                if arguments[-1] == "-getProperty:WindowsSdkDir":
                    return str(sdk)
                self.fail(f"Unexpected or mutating prerequisite command: {arguments}")

            with patch.object(smoke, "run", side_effect=query), patch.object(smoke, "latest_toolset", return_value="v145"):
                projects = smoke.prepare_mfc_projects(root, msbuild, {})
                self.assertEqual({(directory.name, target) for directory, _, target in projects},
                                 {(f"mfc-{toolset}-{target}", target) for toolset in ("latest", "v143", "v142")
                                  for target in ("Win32", "x64", "ARM64")})
                for path in files:
                    with self.subTest(missing=path):
                        path.unlink()
                        with self.assertRaisesRegex(RuntimeError, "Missing.*prerequisite"):
                            smoke.prepare_mfc_projects(root, msbuild, {})
                        path.touch()


if __name__ == "__main__":
    unittest.main()
