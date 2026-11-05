"""Build the complete Windows x64 toolchain matrix in temporary projects.

--verify-only never provisions host tools or changes persistent configuration.
Project-local restores (NuGet and the manifest-owned fmt dependency) need network.
--provision runs only the explicit windows-build task, twice, on disposable CI.
ARM64 artifacts are inspected, never advertised as executed on this x64 host.
"""

import argparse
import json
import os
from pathlib import Path
import platform
import re
import shutil
import struct
import subprocess
import tempfile


REPO = Path(__file__).resolve().parents[1]
MACHINES = {"Win32": 0x14C, "x64": 0x8664, "ARM64": 0xAA64}


def run(arguments, *, cwd, env, timeout=3600, print_output=True, stream=False):
    print("+ " + subprocess.list2cmdline([str(arg) for arg in arguments]), flush=True)
    result = subprocess.run(arguments, cwd=cwd, env=env, capture_output=not stream,
                            text=True, encoding="utf-8", errors="backslashreplace", timeout=timeout)
    if print_output and result.stdout:
        print(result.stdout, end="" if result.stdout.endswith("\n") else "\n", flush=True)
    if result.stderr:
        print(result.stderr, end="" if result.stderr.endswith("\n") else "\n", flush=True)
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {arguments!r}")
    return (result.stdout or "").strip()


def executable(name):
    found = shutil.which(name)
    if not found:
        raise RuntimeError(f"Required executable is not on PATH: {name}")
    return str(Path(found).resolve())


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return path


def check_pe(path, target):
    with path.open("rb") as stream:
        if stream.read(2) != b"MZ":
            raise RuntimeError(f"Not a PE executable: {path}")
        stream.seek(0x3C)
        offset = struct.unpack("<I", stream.read(4))[0]
        stream.seek(offset)
        if stream.read(4) != b"PE\0\0":
            raise RuntimeError(f"Missing PE signature: {path}")
        machine = struct.unpack("<H", stream.read(2))[0]
    if machine != MACHINES[target]:
        raise RuntimeError(f"{path}: expected {target}, found PE machine 0x{machine:04x}")
    print(f"PE {target}: {path}", flush=True)


def check_output(path, target, marker, *, cwd, env):
    check_pe(path, target)
    if target != "ARM64":
        output = run([str(path)], cwd=cwd, env=env, timeout=120)
        if marker not in output:
            raise RuntimeError(f"Missing runtime marker {marker!r}: {output!r}")


def is_administrator():
    import ctypes
    from ctypes import wintypes

    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    security = ctypes.WinDLL("advapi32", use_last_error=True)
    kernel.GetCurrentProcess.restype = wintypes.HANDLE
    security.OpenProcessToken.argtypes = (wintypes.HANDLE, wintypes.DWORD, ctypes.POINTER(wintypes.HANDLE))
    security.GetTokenInformation.argtypes = (wintypes.HANDLE, ctypes.c_int, wintypes.LPVOID,
                                            wintypes.DWORD, ctypes.POINTER(wintypes.DWORD))
    kernel.CloseHandle.argtypes = (wintypes.HANDLE,)
    token = wintypes.HANDLE()
    if not security.OpenProcessToken(kernel.GetCurrentProcess(), 0x0008, ctypes.byref(token)):
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        elevated, size = wintypes.DWORD(), wintypes.DWORD()
        if not security.GetTokenInformation(token, 20, ctypes.byref(elevated),
                                            ctypes.sizeof(elevated), ctypes.byref(size)):
            raise ctypes.WinError(ctypes.get_last_error())
        return bool(elevated.value)
    finally:
        kernel.CloseHandle(token)


def visual_studio(env):
    vswhere = Path(env.get("PROGRAMFILES(X86)", r"C:\Program Files (x86)")) / "Microsoft Visual Studio/Installer/vswhere.exe"
    if not vswhere.is_file():
        raise RuntimeError("Missing vswhere: prepare Build Tools explicitly with mise run windows-build; verification never installs tools.")
    config = json.loads((REPO / "scripts/windows-build-tools.vsconfig").read_text(encoding="utf-8-sig"))
    output = run([str(vswhere), "-products", "Microsoft.VisualStudio.Product.BuildTools",
                  "-version", "[18.0,19.0)", "-requires", *config["components"],
                  "-format", "json", "-utf8"], cwd=REPO, env=env)
    instances = json.loads(output)
    instances = [item for item in instances if item.get("isComplete") and
                 item.get("isLaunchable") and not item.get("isPrerelease") and
                 not item.get("isRebootRequired", False) and
                 item.get("productId") == "Microsoft.VisualStudio.Product.BuildTools" and
                 item.get("channelId") == "VisualStudio.18.Release" and
                 18 <= int(item["installationVersion"].split(".")[0]) < 19]
    if len(instances) != 1:
        raise RuntimeError("Expected one complete stable VS 2026 Build Tools instance with every tracked component. "
                           "Use Visual Studio Installer to maintain Build Tools with scripts/windows-build-tools.vsconfig; "
                           "resolve missing components, unhealthy state, or ambiguous instances before verification.")
    instance = instances[0]
    root = Path(instance["installationPath"])
    print(f"VS 2026: {instance['installationVersion']} at {root}")
    return root, root / "MSBuild/Current/Bin/MSBuild.exe"


def fresh_environment(root, env):
    """Source the real managed profile in a fresh, non-project Windows PS shell."""
    import winreg

    def registry_values(hive, key_path):
        with winreg.OpenKey(hive, key_path) as key:
            return {name.upper(): value for name, value, kind in
                    (winreg.EnumValue(key, index) for index in range(winreg.QueryInfoKey(key)[1]))
                    if kind in (winreg.REG_SZ, winreg.REG_EXPAND_SZ)}

    machine = registry_values(winreg.HKEY_LOCAL_MACHINE,
                              r"SYSTEM\CurrentControlSet\Control\Session Manager\Environment")
    user = registry_values(winreg.HKEY_CURRENT_USER, "Environment")
    fresh = {name.upper(): value for name, value in env.items()}
    fresh.update(machine)
    fresh.update(user)
    # Do not inherit a project-selected toolchain or mise SDK path from CI.
    fresh.pop("RUSTUP_TOOLCHAIN", None)
    fresh["PATH"] = ";".join([machine.get("PATH", ""), user.get("PATH", ""), str(Path(executable("mise")).parent)])
    fresh = {name: re.sub(r"%([^%]+)%", lambda match: fresh.get(match[1].upper(), match[0]), value)
             for name, value in fresh.items()}
    for name in ("DOTNET_ROOT", "CARGO_HOME", "RUSTUP_HOME", "VCPKG_ROOT"):
        if not user.get(name) or not Path(fresh[name]).is_absolute():
            raise RuntimeError(f"Missing persistent absolute user environment value: {name}")
    rendered = run([executable("chezmoi"), "--source", str(REPO), "--config", str(root / "empty.toml"),
                    "execute-template", "--file", str(REPO / "home/.chezmoitemplates/powershell-mise-profile")],
                   cwd=root, env=env)
    profile = write(root / "managed-profile.ps1", rendered)
    output = root / "fresh-environment.json"
    proof = write(root / "fresh-shell.ps1", r"""$ErrorActionPreference = 'Stop'
. $env:SMOKE_PROFILE
$commands = @{}
foreach ($name in @('dotnet', 'cargo', 'rustc', 'vcpkg')) {
    $commands[$name] = @(Get-Command $name -CommandType Application -ErrorAction Stop)[0].Source
}
@{ commands = $commands; environment = [Environment]::GetEnvironmentVariables('Process') } |
    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $env:SMOKE_ENVIRONMENT -Encoding UTF8
""")
    fresh.update(SMOKE_PROFILE=str(profile), SMOKE_ENVIRONMENT=str(output))
    powershell = Path(env["SYSTEMROOT"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
    run([str(powershell), "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", str(proof)], cwd=root, env=fresh)
    result = json.loads(output.read_text(encoding="utf-8-sig"))
    active = {name.upper(): str(value) for name, value in result["environment"].items()}
    expected = {"dotnet": Path(active["DOTNET_ROOT"]) / "dotnet.exe",
                "cargo": Path(active["CARGO_HOME"]) / "bin/cargo.exe",
                "rustc": Path(active["CARGO_HOME"]) / "bin/rustc.exe",
                "vcpkg": Path(active["VCPKG_ROOT"]) / "vcpkg.exe"}
    for name, path in expected.items():
        if Path(result["commands"][name]).resolve() != path.resolve():
            raise RuntimeError(f"Fresh managed profile selected wrong {name}: {result['commands'][name]}; expected {path}")
        print(f"Fresh shell {name}: {path}")
    return active


def latest_toolset(msbuild, target):
    targets = msbuild.parents[2] / "Microsoft/VC"
    candidates = [
        toolset.name for toolset in targets.glob(f"v*/Platforms/{target}/PlatformToolsets/v*")
        if toolset.is_dir() and re.fullmatch(r"v\d+", toolset.name)
    ]
    if not candidates:
        raise RuntimeError(f"No installed MSVC platform toolset found for {target}: {targets}")
    return max(candidates, key=lambda name: int(name[1:]))


def vc_project(directory, toolset, target, *, dependency=False):
    toolset_property = f"<PlatformToolset>{toolset}</PlatformToolset>"
    # SDK 26100 requires ARM64 intrinsics absent from the v142 compiler.
    sdk_version = "10.0.22621.0" if toolset == "v142" else "10.0.26100.0"
    properties = ("<VcpkgEnabled>true</VcpkgEnabled><VcpkgEnableManifest>true</VcpkgEnableManifest>"
                  "<VcpkgManifestInstall>true</VcpkgManifestInstall>"
                  "<VcpkgManifestRoot>$(ProjectDir)</VcpkgManifestRoot>"
                  "<VcpkgInstalledDir>$(ProjectDir)vcpkg_installed/</VcpkgInstalledDir>"
                  f"<VcpkgTriplet>{target.lower()}-windows-static</VcpkgTriplet>"
                  if dependency else "<UseOfMfc>Static</UseOfMfc><VcpkgEnabled>false</VcpkgEnabled>")
    return write(directory / "smoke.vcxproj", fr"""<Project DefaultTargets="Build" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <ItemGroup Label="ProjectConfigurations"><ProjectConfiguration Include="Release|{target}"><Configuration>Release</Configuration><Platform>{target}</Platform></ProjectConfiguration></ItemGroup>
  <PropertyGroup Label="Globals"><ProjectGuid>{{53E6909B-8686-4913-A248-858CE2876B87}}</ProjectGuid><WindowsTargetPlatformVersion>{sdk_version}</WindowsTargetPlatformVersion></PropertyGroup>
  <Import Project="$(VCTargetsPath)\Microsoft.Cpp.Default.props" />
  <PropertyGroup Label="Configuration"><ConfigurationType>Application</ConfigurationType><CharacterSet>Unicode</CharacterSet>{toolset_property}{properties}</PropertyGroup>
  <Import Project="$(VCTargetsPath)\Microsoft.Cpp.props" />
  <PropertyGroup><OutDir>$(ProjectDir)out\</OutDir><IntDir>$(ProjectDir)obj\</IntDir><TargetName>smoke</TargetName></PropertyGroup>
  <ItemDefinitionGroup><ClCompile><RuntimeLibrary>MultiThreaded</RuntimeLibrary><PrecompiledHeader>NotUsing</PrecompiledHeader><AdditionalOptions>/utf-8 %(AdditionalOptions)</AdditionalOptions></ClCompile><Link><SubSystem>Console</SubSystem></Link></ItemDefinitionGroup>
  <ItemGroup><ClCompile Include="main.cpp" /></ItemGroup>
  <Import Project="$(VCTargetsPath)\Microsoft.Cpp.targets" />
</Project>
""")


def prepare_mfc_projects(root, msbuild, env):
    projects = []
    for toolset in (None, "v143", "v142"):
        for target in ("Win32", "x64", "ARM64"):
            directory = root / f"mfc-{toolset or 'latest'}-{target}"
            write(directory / "main.cpp", '#include <afx.h>\n#include <cwchar>\nint main() { CString text(L"mfc-smoke"); std::wprintf(L"%ls\\n", text.GetString()); return text == L"mfc-smoke" ? 0 : 1; }\n')
            project = vc_project(directory, toolset or latest_toolset(msbuild, target), target)
            args = [str(msbuild), str(project), "/nologo", "/p:Configuration=Release", f"/p:Platform={target}"]
            selected = run(args + ["-getProperty:PlatformToolset"], cwd=directory, env=env)
            if toolset and selected != toolset:
                raise RuntimeError(f"Requested {toolset} but MSBuild selected {selected!r}")
            if not selected:
                raise RuntimeError("MSBuild did not report a default PlatformToolset")
            selected_version = run(args + ["-getProperty:VCToolsVersion"], cwd=directory, env=env)
            if toolset is None:
                default_version = (msbuild.parents[3] / "VC/Auxiliary/Build/Microsoft.VCToolsVersion.default.txt").read_text(encoding="utf-8-sig").strip()
                if selected_version != default_version:
                    raise RuntimeError(f"Latest toolset selected {selected_version}, expected {default_version}")
            print(f"MFC {target} selected toolset: {selected}, compiler {selected_version}")
            compiler_root = msbuild.parents[3] / "VC/Tools/MSVC" / selected_version
            architecture = {"Win32": "x86", "x64": "x64", "ARM64": "arm64"}[target]
            for path in (compiler_root / f"bin/Hostx64/{architecture}/cl.exe",
                         compiler_root / "atlmfc/include/afx.h",
                         compiler_root / f"atlmfc/lib/{architecture}/uafxcw.lib"):
                if not path.is_file():
                    raise RuntimeError(f"Missing {selected} {target} compiler/MFC prerequisite: {path}")
            sdk = Path(run(args + ["-getProperty:WindowsSdkDir"], cwd=directory, env=env))
            sdk_version = "10.0.22621.0" if selected == "v142" else "10.0.26100.0"
            for path in (sdk / f"Include/{sdk_version}/um/Windows.h",
                         sdk / f"Lib/{sdk_version}/um/{architecture}/kernel32.lib",
                         sdk / f"Lib/{sdk_version}/ucrt/{architecture}/ucrt.lib"):
                if not path.is_file():
                    raise RuntimeError(f"Missing Windows SDK {sdk_version} {target} prerequisite: {path}")
            projects.append((directory, args, target))
    return projects


def mfc_builds(projects, env):
    for directory, args, target in projects:
        run(args + ["/t:Build"], cwd=directory, env=env)
        check_output(directory / "out/smoke.exe", target, "mfc-smoke", cwd=directory, env=env)


def wpf_sources(directory):
    write(directory / "App.xaml", '<Application x:Class="Smoke.App" xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" />\n')
    write(directory / "App.xaml.cs", '''using System;
using System.Windows;
using System.Windows.Controls;
namespace Smoke {
    public partial class App : Application {
        protected override void OnStartup(StartupEventArgs e) {
            base.OnStartup(e);
            var window = new MainWindow();
            if (((TextBlock)window.Content).Text != "wpf-smoke") throw new Exception("XAML content missing");
            Console.WriteLine("wpf-smoke");
            Shutdown(0);
        }
    }
}
''')
    write(directory / "MainWindow.xaml", '<Window x:Class="Smoke.MainWindow" xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"><TextBlock Text="wpf-smoke" /></Window>\n')
    write(directory / "MainWindow.xaml.cs", 'namespace Smoke { public partial class MainWindow : System.Windows.Window { public MainWindow() { InitializeComponent(); } } }\n')


def preflight_languages(root, env):
    versions = dotnet_sdks(root, env)
    for framework in ("v4.8", "v4.8.1"):
        references = Path(env.get("PROGRAMFILES(X86)", r"C:\Program Files (x86)")) / "Reference Assemblies/Microsoft/Framework/.NETFramework" / framework
        for name in ("mscorlib.dll", "PresentationFramework.dll", "PresentationCore.dll", "WindowsBase.dll"):
            if not (references / name).is_file():
                raise RuntimeError(f"Missing {framework} targeting assembly: {references / name}")
    rustup = Path(env["CARGO_HOME"]) / "bin/rustup.exe"
    installed = run([str(rustup), "target", "list", "--installed", "--toolchain",
                     "stable-x86_64-pc-windows-msvc"], cwd=root, env=env).splitlines()
    for target in ("x86_64-pc-windows-msvc", "aarch64-pc-windows-msvc"):
        if target not in installed:
            raise RuntimeError(f"Missing installed stable MSVC Rust target: {target}")
    return versions


def preflight_vcpkg(root, msbuild, env):
    vcpkg_root = Path(env["VCPKG_ROOT"])
    run([str(vcpkg_root / "vcpkg.exe"), "version"], cwd=root, env=env)
    revision = run([executable("git"), "-C", str(vcpkg_root), "rev-parse", "HEAD"], cwd=root, env=env)
    for target in ("x64", "ARM64"):
        directory = root / f"vcpkg-{target}"
        write(directory / "main.cpp", '#include <fmt/core.h>\nint main() { fmt::print("vcpkg-smoke\\n"); }\n')
        write(directory / "vcpkg.json", json.dumps({"name": "dotfiles-build-smoke", "version-string": "1", "builtin-baseline": revision, "dependencies": ["fmt"]}))
        project = vc_project(directory, latest_toolset(msbuild, target), target, dependency=True)
        args = [str(msbuild), str(project), "/nologo", "/p:Configuration=Release", f"/p:Platform={target}"]
        selected = run(args + ["-getProperty:VcpkgRoot"], cwd=directory, env=env)
        if not selected or Path(selected).resolve() != vcpkg_root.resolve():
            raise RuntimeError(f"User-wide MSBuild integration selected {selected!r}, expected {vcpkg_root}")


def dotnet_sdks(root, env):
    dotnet = str(Path(env["DOTNET_ROOT"]) / "dotnet.exe")
    listed = run([dotnet, "--list-sdks"], cwd=root, env=env)
    run([dotnet, "--list-runtimes"], cwd=root, env=env)
    selected = {}
    for major in (8, 10):
        versions = re.findall(rf"^({major}\.\d+\.\d+)\s+\[([^\]]+)\]", listed, re.MULTILINE)
        if not versions:
            raise RuntimeError(f"Missing stable .NET SDK {major} in shared root")
        version, sdk_path = max(versions, key=lambda item: tuple(map(int, item[0].split('.'))))
        if Path(sdk_path).resolve() != (Path(env["DOTNET_ROOT"]) / "sdk").resolve():
            raise RuntimeError(f"SDK {version} came from a different root: {sdk_path}")
        selected[major] = version
    return selected


def dotnet_builds(root, msbuild, env, versions):
    dotnet = str(Path(env["DOTNET_ROOT"]) / "dotnet.exe")
    for major, version in versions.items():
        for target in ("x64", "ARM64"):
            directory = root / f"wpf-net{major}-{target}"
            wpf_sources(directory)
            write(directory / "global.json", json.dumps({"sdk": {"version": version, "rollForward": "disable", "allowPrerelease": False}}))
            project = write(directory / "smoke.csproj", f'''<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net{major}.0-windows</TargetFramework><UseWPF>true</UseWPF><RuntimeIdentifier>win-{target.lower()}</RuntimeIdentifier><SelfContained>false</SelfContained><PlatformTarget>{target}</PlatformTarget></PropertyGroup>
</Project>
''')
            if run([dotnet, "--version"], cwd=directory, env=env) != version:
                raise RuntimeError(f"global.json did not select SDK {version}")
            run([dotnet, "build", str(project), "-c", "Release", "-o", str(directory / "out")], cwd=directory, env=env)
            check_output(directory / "out/smoke.exe", target, "wpf-smoke", cwd=directory, env=env)
    for framework in ("v4.8", "v4.8.1"):
        directory = root / f"wpf-framework-{framework}"
        wpf_sources(directory)
        references = Path(env.get("PROGRAMFILES(X86)", r"C:\Program Files (x86)")) / "Reference Assemblies/Microsoft/Framework/.NETFramework" / framework
        for name in ("mscorlib.dll", "PresentationFramework.dll", "WindowsBase.dll"):
            if not (references / name).is_file():
                raise RuntimeError(f"Missing {framework} targeting assembly: {references / name}")
        project = write(directory / "smoke.csproj", fr'''<Project DefaultTargets="Build" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <PropertyGroup><Configuration>Release</Configuration><Platform>x64</Platform><PlatformTarget>x64</PlatformTarget><OutputType>Exe</OutputType><AssemblyName>smoke</AssemblyName><RootNamespace>Smoke</RootNamespace><TargetFrameworkVersion>{framework}</TargetFrameworkVersion><OutputPath>out\</OutputPath><ProjectTypeGuids>{{60dc8134-eba5-43b8-bcc9-bb4bc16c2548}};{{fae04ec0-301f-11d3-bf4b-00c04f79efbc}}</ProjectTypeGuids></PropertyGroup>
  <ItemGroup><Reference Include="System" /><Reference Include="System.Core" /><Reference Include="System.Xaml" /><Reference Include="WindowsBase" /><Reference Include="PresentationCore" /><Reference Include="PresentationFramework" /></ItemGroup>
  <ItemGroup><ApplicationDefinition Include="App.xaml" /><Page Include="MainWindow.xaml" /><Compile Include="App.xaml.cs" /><Compile Include="MainWindow.xaml.cs" /></ItemGroup>
  <Import Project="$(MSBuildToolsPath)\Microsoft.CSharp.targets" />
</Project>
''')
        run([str(msbuild), str(project), "/nologo", "/t:Build", "/p:Configuration=Release", "/p:Platform=x64"], cwd=directory, env=env)
        check_output(directory / "out/smoke.exe", "x64", "wpf-smoke", cwd=directory, env=env)


def developer_environment(vs, target, root, env):
    command = write(root / f"vcvars-{target}.cmd", f'@echo off\r\ncall "{vs / "VC/Auxiliary/Build/vcvarsall.bat"}" {target} >nul\r\nif errorlevel 1 exit /b %errorlevel%\r\nset\r\n')
    output = run([env.get("COMSPEC", "cmd.exe"), "/d", "/c", str(command)], cwd=root, env=env, print_output=False)
    result = env.copy()
    for line in output.splitlines():
        name, sep, value = line.partition("=")
        if sep and name and not name.startswith("="):
            result[name.upper()] = value
    return result


def rust_builds(root, vs, env):
    rustup = str(Path(env["CARGO_HOME"]) / "bin/rustup.exe")
    # Select the managed toolchain for this project without replacing a user's
    # existing default or project override. rustup run never installs a toolchain.
    selected = [rustup, "run", "stable-x86_64-pc-windows-msvc"]
    version = run(selected + ["rustc", "--version", "--verbose"], cwd=root, env=env)
    if "host: x86_64-pc-windows-msvc" not in version or not re.search(r"^release: \d+\.\d+\.\d+$", version, re.MULTILINE):
        raise RuntimeError("The managed toolchain is not stable native x64 MSVC Rust")
    run(selected + ["cargo", "--version"], cwd=root, env=env)
    directory = root / "rust"
    write(directory / "Cargo.toml", '[package]\nname = "smoke"\nversion = "0.1.0"\nedition = "2021"\n')
    write(directory / "src/main.rs", 'fn main() { println!("rust-smoke"); }\n')
    for target, arch, vcarch in (("x86_64-pc-windows-msvc", "x64", "amd64"), ("aarch64-pc-windows-msvc", "ARM64", "amd64_arm64")):
        child = developer_environment(vs, vcarch, root, env)
        run(selected + ["cargo", "build", "--release", "--target", target], cwd=directory, env=child)
        check_output(directory / f"target/{target}/release/smoke.exe", arch, "rust-smoke", cwd=directory, env=child)


def vcpkg_builds(root, msbuild, env):
    vcpkg_root = Path(env["VCPKG_ROOT"])
    run([str(vcpkg_root / "vcpkg.exe"), "version"], cwd=root, env=env)
    revision = run([executable("git"), "-C", str(vcpkg_root), "rev-parse", "HEAD"], cwd=root, env=env)
    for target in ("x64", "ARM64"):
        directory = root / f"vcpkg-{target}"
        write(directory / "main.cpp", '#include <fmt/core.h>\nint main() { fmt::print("vcpkg-smoke\\n"); }\n')
        write(directory / "vcpkg.json", json.dumps({"name": "dotfiles-build-smoke", "version-string": "1", "builtin-baseline": revision, "dependencies": ["fmt"]}))
        project = vc_project(directory, latest_toolset(msbuild, target), target, dependency=True)
        args = [str(msbuild), str(project), "/nologo", "/p:Configuration=Release", f"/p:Platform={target}"]
        selected = run(args + ["-getProperty:VcpkgRoot"], cwd=directory, env=env)
        if not selected or Path(selected).resolve() != vcpkg_root.resolve():
            raise RuntimeError(f"User-wide MSBuild integration selected {selected!r}, expected {vcpkg_root}")
        # No explicit import or /p:VcpkgRoot: this must consume user-wide integration.
        run(args + ["/t:Build"], cwd=directory, env=env)
        check_output(directory / "out/smoke.exe", target, "vcpkg-smoke", cwd=directory, env=env)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--verify-only", action="store_true")
    mode.add_argument("--provision", action="store_true")
    args = parser.parse_args()
    if os.name != "nt" or platform.machine().lower() not in ("amd64", "x86_64") or os.environ.get("PROCESSOR_ARCHITEW6432"):
        raise RuntimeError("The build smoke requires a native Windows x64 host and Python")
    env = os.environ.copy()
    elevated = is_administrator()
    print(f"Windows verification token: IsElevated={elevated}", flush=True)
    if elevated:
        raise RuntimeError("Verification requires a non-elevated session. Open an ordinary terminal; run privileged preparation separately.")
    if args.provision:
        if env.get("GITHUB_ACTIONS") != "true" or env.get("RUNNER_ENVIRONMENT") != "github-hosted":
            raise RuntimeError("--provision is restricted to disposable GitHub-hosted Windows x64 runners")
        # Installer and integration changes remain only on the disposable host.
        # Both invocations must succeed, including component reconciliation.
        for application in (1, 2):
            print(f"Explicit build-environment application {application}/2", flush=True)
            run([executable("mise"), "run", "windows-build"], cwd=REPO, env=env, timeout=10800, stream=True)
            visual_studio(env)
    vs, msbuild = visual_studio(env)
    with tempfile.TemporaryDirectory(prefix="windows-build-smoke-") as scratch:
        root = Path(scratch)
        write(root / "empty.toml", "")
        active = fresh_environment(root, env)
        try:
            projects = prepare_mfc_projects(root, msbuild, active)
            versions = preflight_languages(root, active)
            preflight_vcpkg(root, msbuild, active)
        except (RuntimeError, OSError) as error:
            raise RuntimeError(f"Build prerequisites are not ready: {error}\n"
                               "Use Visual Studio Installer for existing VS component/repair maintenance, or explicitly run "
                               "mise run windows-build to prepare missing tools in the intended user's environment; "
                               "verification never installs or elevates.") from error
        mfc_builds(projects, active)
        dotnet_builds(root, msbuild, active, versions)
        rust_builds(root, vs, active)
        vcpkg_builds(root, msbuild, active)
    print("PASS: all required MFC, WPF, Framework, Rust, vcpkg and fresh-profile proofs completed. ARM64 outputs were cross-built and PE-inspected, not executed.")


if __name__ == "__main__":
    main()
