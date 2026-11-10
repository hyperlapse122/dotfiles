"""Compile, identify and run native GNU x64 programs using explicitly provisioned roots.

Never installs host tools. Project-local dotnet restores and vcpkg builds need network.
Use --home to verify isolated CI provisioning rather than the account's home.
"""

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


REPO = Path(__file__).resolve().parents[1]


def run(arguments, *, cwd, env, timeout=1200):
    arguments = [str(value) for value in arguments]
    print("+ " + subprocess.list2cmdline(arguments), flush=True)
    result = subprocess.run(arguments, cwd=cwd, env=env, capture_output=True, text=True,
                            encoding="utf-8", errors="backslashreplace", timeout=timeout)
    print(result.stdout, end="", flush=True)
    if result.stderr:
        print(result.stderr, end="", flush=True)
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {arguments!r}")
    return result.stdout.strip()


def native_output(path, *, cwd, env):
    architecture = run(["/usr/bin/file", "-b", path], cwd=cwd, env=env)
    if "ELF 64-bit" not in architecture or "x86-64" not in architecture:
        raise RuntimeError(f"Expected native x64 ELF artifact, got {architecture!r}: {path}")
    output = run([path], cwd=cwd, env=env, timeout=60)
    if output != "dotfiles-native-ok":
        raise RuntimeError(f"Unexpected runtime output: {output!r}")


def verify(home):
    import importlib.util
    spec = importlib.util.spec_from_file_location("linux_platform", REPO / "scripts/linux-platform.py")
    probe = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(probe)
    report = probe.inspect_host()
    if not report["supported"]:
        raise RuntimeError("; ".join(report["blockers"]))
    env = os.environ.copy()
    env["HOME"] = str(home)
    env["DOTNET_CLI_HOME"] = str(home)
    state = home / ".local/share/dotfiles/build"
    for name in ("DOTNET_ROOT", "CARGO_HOME", "RUSTUP_HOME", "VCPKG_ROOT"):
        value = (state / name).read_text(encoding="utf-8").strip()
        if not Path(value).is_absolute():
            raise RuntimeError(f"Published {name} is not an absolute path")
        env[name] = value
    env.pop("RUSTUP_TOOLCHAIN", None)
    env["PATH"] = os.pathsep.join([str(state / "bin"), str(Path(env["CARGO_HOME"]) / "bin"),
                                   env["DOTNET_ROOT"], env["VCPKG_ROOT"], env.get("PATH", "")])
    clean = env.copy()
    for name in ("DOTNET_ROOT", "CARGO_HOME", "RUSTUP_HOME", "VCPKG_ROOT", "RUSTUP_TOOLCHAIN"):
        clean.pop(name, None)
    clean["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    fragment = REPO / "home/dot_config/dotfiles/path.sh"
    with tempfile.TemporaryDirectory(prefix="linux native smoke ") as scratch:
        root = Path(scratch)
        (root / "rust-toolchain.toml").write_text(
            '[toolchain]\nchannel = "stable-x86_64-unknown-linux-gnu"\n', encoding="utf-8")
        env.update(DOTNET_CLI_HOME=str(root / "dotnet-home"), NUGET_PACKAGES=str(root / "nuget"),
                   VCPKG_DOWNLOADS=str(root / "downloads"),
                   VCPKG_BINARY_SOURCES=f"clear;files,{root / 'binary-cache'},readwrite",
                   VCPKG_DISABLE_METRICS="1")
        (root / "binary-cache").mkdir()
        clean["DOTNET_CLI_HOME"] = env["DOTNET_CLI_HOME"]
        discovery = run(["/bin/bash", "--noprofile", "--norc", "-c",
                         'set -eu; . "$1"; command -v dotnet; command -v rustc; command -v cmake; command -v ninja; command -v vcpkg; command -v python; command -v pwsh; python --version; pwsh --version; dotnet --list-sdks; rustc --version --verbose',
                         "fresh-build-shell", fragment], cwd=root, env=clean)
        evidence = {"fresh-shell": discovery}
        # Real compiler output, execution and architecture are all required.
        source = root / "native.cpp"
        source.write_text('#include <iostream>\nint main(){std::cout << "dotfiles-native-ok\\n";}\n', encoding="utf-8")
        binary = root / "native-cpp"
        evidence["gcc"] = run(["c++", "--version"], cwd=root, env=env)
        run(["c++", source, "-o", binary], cwd=root, env=env)
        native_output(binary, cwd=root, env=env)
        rust = root / "native.rs"
        rust.write_text('fn main(){println!("dotfiles-native-ok");}\n', encoding="utf-8")
        evidence["rust"] = run(["rustc", "--version", "--verbose"], cwd=root, env=env)
        if "host: x86_64-unknown-linux-gnu" not in evidence["rust"]:
            raise RuntimeError("Rust uses the wrong host architecture")
        run(["rustc", "--target", "x86_64-unknown-linux-gnu", rust, "-o", root / "native-rust"], cwd=root, env=env)
        native_output(root / "native-rust", cwd=root, env=env)
        sdks = run(["dotnet", "--list-sdks"], cwd=root, env=env).splitlines()
        for major in (8, 10):
            candidates = [line.split()[0] for line in sdks if line.startswith(f"{major}.")]
            if not candidates:
                raise RuntimeError(f"SDK {major} is missing")
            project = root / f"dotnet-{major}"
            project.mkdir()
            (project / "global.json").write_text(json.dumps({"sdk": {"version": candidates[-1], "rollForward": "disable"}}), encoding="utf-8")
            (project / "sample.csproj").write_text(f'<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net{major}.0</TargetFramework><RuntimeIdentifier>linux-x64</RuntimeIdentifier></PropertyGroup></Project>', encoding="utf-8")
            (project / "Program.cs").write_text('System.Console.WriteLine("dotfiles-native-ok");\n', encoding="utf-8")
            evidence[f"dotnet-{major}"] = run(["dotnet", "--version"], cwd=project, env=env)
            run(["dotnet", "publish", "-c", "Release", "--self-contained", "false", "-o", "out"], cwd=project, env=env)
            native_output(project / "out/sample", cwd=project, env=env)
        project = root / "vcpkg-project"
        project.mkdir()
        (project / "vcpkg.json").write_text(json.dumps({"name": "dotfiles-native-smoke", "version-string": "1", "dependencies": ["fmt"]}), encoding="utf-8")
        (project / "main.cpp").write_text('#include <fmt/core.h>\nint main(){fmt::print("dotfiles-native-ok\\n");}\n', encoding="utf-8")
        (project / "CMakeLists.txt").write_text('cmake_minimum_required(VERSION 3.21)\nproject(native_smoke LANGUAGES CXX)\nfind_package(fmt CONFIG REQUIRED)\nadd_executable(native-smoke main.cpp)\ntarget_link_libraries(native-smoke PRIVATE fmt::fmt)\n', encoding="utf-8")
        toolchain = Path(env["VCPKG_ROOT"]) / "scripts/buildsystems/vcpkg.cmake"
        run(["cmake", "-S", project, "-B", project / "build", "-G", "Ninja", f"-DCMAKE_TOOLCHAIN_FILE={toolchain}", "-DVCPKG_TARGET_TRIPLET=x64-linux",
             f"-DVCPKG_INSTALL_OPTIONS=--x-buildtrees-root={root / 'buildtrees'};--x-packages-root={root / 'packages'}"], cwd=project, env=env, timeout=3600)
        run(["cmake", "--build", project / "build"], cwd=project, env=env)
        native_output(project / "build/native-smoke", cwd=project, env=env)
        evidence["vcpkg"] = run(["vcpkg", "version"], cwd=root, env=env)
    return {"target": "linux-x64", "status": "passed", "checks": ["cpp", "rust", "dotnet-8", "dotnet-10", "vcpkg-fmt"], "versions": evidence}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", type=Path, default=Path.home(), help="Home containing explicitly provisioned build roots")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    try:
        result = verify(args.home.resolve())
    except Exception as error:
        if args.report:
            args.report.parent.mkdir(parents=True, exist_ok=True)
            args.report.write_text(json.dumps({"status": "failed", "error": str(error)}, indent=2) + "\n", encoding="utf-8")
        raise
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
