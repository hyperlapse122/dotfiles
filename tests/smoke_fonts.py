"""Stage pinned releases and exercise native discovery with temporary owned fonts."""

import argparse
from contextlib import contextmanager
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import platform
import secrets
import shutil
import struct
import subprocess
import tempfile
import threading
from urllib.parse import quote, unquote, urlparse


REPO = Path(__file__).resolve().parents[1]


@contextmanager
def cached_assets(lock, directory):
    if directory is None:
        yield
        return
    server = ThreadingHTTPServer(("127.0.0.1", 0), partial(SimpleHTTPRequestHandler, directory=str(directory)))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        for pin in lock.values():
            name = unquote(Path(urlparse(pin["url"]).path).name)
            pin["url"] = f"http://127.0.0.1:{server.server_port}/{quote(name)}"
        yield
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


def run(command, env):
    result = subprocess.run(command, env=env, capture_output=True, text=True,
                            encoding="utf-8", errors="replace", timeout=600)
    if result.returncode:
        raise RuntimeError(f"{command[0]} failed:\n{result.stdout}\n{result.stderr}")
    return result.stdout


def font_name(path, name_id):
    data = path.read_bytes()
    count = struct.unpack_from(">H", data, 4)[0]
    for index in range(count):
        entry = 12 + index * 16
        if data[entry:entry + 4] != b"name":
            continue
        base = struct.unpack_from(">I", data, entry + 8)[0]
        records, strings = struct.unpack_from(">HH", data, base + 2)
        names = []
        for record in range(records):
            plat, encoding, language, kind, length, offset = struct.unpack_from(">HHHHHH", data, base + 6 + record * 12)
            if kind == name_id and plat in (0, 3):
                start = base + strings + offset
                text = data[start:start + length].decode("utf-16-be")
                names.append((language != 0x409, text))
        if names:
            return min(names)[1]
    raise ValueError(f"Font has no name {name_id}: {path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--asset-cache", type=Path, help="Reuse downloaded official release archives")
    args = parser.parse_args()
    lock = json.loads((REPO / "home/.chezmoidata/font-lock.json").read_text())["fontLocks"]
    prefix = "smoke-" + secrets.token_hex(5) + "-"
    lock = {prefix + name: pin for name, pin in lock.items()}
    with cached_assets(lock, args.asset_cache), tempfile.TemporaryDirectory(
            prefix="font smoke ' ", ignore_cleanup_errors=os.name == "nt") as temporary:
        root = Path(temporary).resolve()
        home, source = root / "home", root / "source"
        home.mkdir()
        source.mkdir()
        for relative in (".chezmoiexternals/fonts.toml.tmpl", "dot_local/share/dotfiles/font-index.tsv.tmpl"):
            target = source / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(REPO / "home" / relative, target)
        data = source / ".chezmoidata"
        data.mkdir()
        (data / "fonts.json").write_text(json.dumps({"fonts": dict.fromkeys(lock, {})}))
        (data / "font-lock.json").write_text(json.dumps({"fontLocks": lock}))
        config = root / "config.toml"
        config.write_text("")
        env = dict(os.environ, HOME=str(home), USERPROFILE=str(home),
                   XDG_DATA_HOME=str(root / "data"), XDG_CONFIG_HOME=str(root / "config"),
                   XDG_CACHE_HOME=str(root / "cache"), LOCALAPPDATA=str(root / "local"),
                   APPDATA=str(root / "roaming"), PSModuleAnalysisCachePath=str(root / "module-cache"))
        run(["chezmoi", "--source", str(source), "--destination", str(home),
             "--config", str(config), "--cache", str(root / "cache"),
             "--persistent-state", str(root / "state.boltdb"), "--force", "apply"], env)
        managed = home / ".local/share/dotfiles"
        index_path = managed / "font-index.tsv"
        state = managed / ("installed-fonts.json" if os.name == "nt" else "installed-fonts.txt")
        if os.name == "nt":
            font_dir = root / "user fonts"
            installer = ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                         str(REPO / "scripts/install-fonts.ps1"),
                         "-AssetRoot", str(managed / "font-assets"), "-IndexPath", str(index_path),
                         "-FontDirectory", str(font_dir), "-StatePath", str(state)]
        else:
            font_dir = (Path.home() / "Library/Fonts" if platform.system() == "Darwin"
                        else root / "data/fonts/dotfiles")
            installer = ["/bin/sh", str(REPO / "scripts/install-fonts.sh"),
                         str(managed / "font-assets"), str(index_path), str(font_dir), str(state)]
        installed = [font_dir / f"dotfiles-{name}-{face['name']}"
                     for name, pin in lock.items() for face in pin["files"]]
        try:
            run(installer, env)
            if not all(path.is_file() for path in installed):
                raise AssertionError("Native installer omitted a locked face")
            before = {path: path.stat().st_mtime_ns for path in installed}
            run(installer, env)
            if before != {path: path.stat().st_mtime_ns for path in installed}:
                raise AssertionError("Unchanged application rewrote font files")
            if os.name == "nt":
                import winreg
                with winreg.OpenKey(winreg.HKEY_CURRENT_USER,
                                    r"Software\Microsoft\Windows NT\CurrentVersion\Fonts") as key:
                    values = {str(winreg.EnumValue(key, i)[1]).lower()
                              for i in range(winreg.QueryInfoKey(key)[1])}
                if any(str(path).lower() not in values for path in installed):
                    raise AssertionError("Missing persistent HKCU font registration")
                listing = root / "list-fonts.ps1"
                # GDI truncates family names to 31 characters; WPF retains the
                # full D2Koding Propo name through native DirectWrite discovery.
                listing.write_text("$ErrorActionPreference = 'Stop'\nAdd-Type -AssemblyName PresentationCore\n"
                                   "$names = foreach ($face in [Windows.Media.Fonts]::SystemTypefaces) {\n"
                                   "  [Windows.Media.GlyphTypeface]$glyph = $null\n"
                                   "  if ($face.TryGetGlyphTypeface([ref]$glyph)) { $glyph.Win32FamilyNames.Values }\n"
                                   "}\n$names | Sort-Object -Unique | ConvertTo-Json\n")
                available = set(json.loads(run(["powershell.exe", "-NoProfile", "-File", str(listing)], env)))
                expected = {font_name(path, 1) for path in installed}
            elif platform.system() == "Darwin":
                available = set(run(["swift", "-e", "import CoreText; "
                                     "for name in CTFontManagerCopyAvailablePostScriptNames() as! [String] "
                                     "{ print(name) }"], env).splitlines())
                expected = {font_name(path, 6) for path in installed}
            else:
                listing = run(["fc-list", "--format=%{file}\n"], env)
                available = set(listing.splitlines())
                expected = {str(path) for path in installed}
            missing = expected - available
            if missing:
                raise AssertionError("Native discovery omitted: " + ", ".join(sorted(missing)))
            print(f"Native {platform.system()} discovery and repeat application passed for {len(installed)} locked faces")
        finally:
            # A failed first install can leave a partial set before its success
            # manifest exists. Cleanup owns this run's unique names either way.
            if os.name == "nt":
                state.write_text(json.dumps({"version": 1, "fonts": [
                    {"name": f"dotfiles-{name}-{face['name']}", "sha256": face["sha256"]}
                    for name, pin in lock.items() for face in pin["files"]]}))
            else:
                state.write_text("".join(path.name + "\n" for path in installed))
            index_path.write_text("")
            pending = []
            try:
                run(installer, env)
            except RuntimeError:
                if os.name != "nt":
                    raise
                import winreg
                with winreg.OpenKey(winreg.HKEY_CURRENT_USER,
                                    r"Software\Microsoft\Windows NT\CurrentVersion\Fonts") as key:
                    if any(prefix in winreg.EnumValue(key, i)[0]
                           for i in range(winreg.QueryInfoKey(key)[1])):
                        raise
                for path in installed:
                    try:
                        path.unlink(missing_ok=True)
                    except PermissionError as error:
                        if error.winerror != 32:
                            raise
                        pending.append(path)
                if not pending:
                    raise
                print(f"Removed all test registrations; Windows retains {len(pending)} locked temporary files at {font_dir}")
            if any(path.exists() for path in installed) and not pending:
                raise AssertionError("Native smoke cleanup left owned fonts behind")


if __name__ == "__main__":
    main()
