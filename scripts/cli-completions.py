#!/usr/bin/env python3
"""Generate managed shell completions from installed repository CLI specifications."""

import argparse
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile


def publish(path, content):
    encoded = content.encode('utf-8')
    if path.exists() and path.read_bytes() == encoded:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix='.completion-', dir=path.parent)
    try:
        with os.fdopen(descriptor, 'wb') as stream:
            stream.write(encoded)
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def generate(destination, usage=None):
    usage = str(Path(usage or shutil.which('usage') or '').resolve())
    if not Path(usage).is_file():
        raise ValueError('Install the mise-managed usage tool before generating completions.')
    binary = Path(destination) / '.local/bin' / ('dotfiles-pinentry.exe' if os.name == 'nt' else 'dotfiles-pinentry')
    if not binary.is_file():
        raise ValueError('Build and install dotfiles-pinentry before generating completions.')
    specification = subprocess.run([str(binary), '--usage-spec'], capture_output=True, text=True,
                                   encoding='utf-8', check=True, timeout=30).stdout
    subprocess.run([usage, 'lint', '-'], input=specification, capture_output=True, text=True,
                   encoding='utf-8', check=True, timeout=30)
    directory = Path(destination) / '.local/share/dotfiles/completions'
    spec_path = directory / 'dotfiles-pinentry.usage.kdl'
    previous_spec = spec_path.read_bytes() if spec_path.exists() else None
    publish(spec_path, specification)
    pending = {}
    try:
        for shell in ('bash', 'zsh', 'powershell'):
            scripts = []
            commands = ['dotfiles-pinentry']
            if shell == 'powershell' and os.name == 'nt':
                commands.append('dotfiles-pinentry.exe')
            for command in commands:
                usage_bin = Path(usage).as_posix()
                if shell == 'powershell':
                    usage_bin = usage_bin.replace("'", "''")
                else:
                    usage_bin = shlex.quote(usage_bin)
                result = subprocess.run([usage, 'generate', 'completion', shell, command,
                                         '--usage-bin', usage_bin, '--file', spec_path.as_posix()],
                                        capture_output=True, text=True, encoding='utf-8', check=True, timeout=30)
                script = result.stdout
                if shell == 'powershell':
                    # Usage 7.3 includes the current token in CommandElements
                    # and appends it again. Only preceding words belong here.
                    original = '$words = $commandAst.CommandElements | ForEach-Object { $_.ToString() }'
                    if original not in script:
                        raise ValueError('Unsupported Usage PowerShell completion generator.')
                    script = script.replace(original,
                        '$words = @($commandAst.CommandElements | Where-Object { $_.Extent.EndOffset -lt $cursorPosition } | ForEach-Object { $_.ToString() })')
                scripts.append(script)
            extension = 'ps1' if shell == 'powershell' else shell
            pending['dotfiles-pinentry.' + extension] = '\n'.join(scripts)
    except BaseException:
        if previous_spec is None:
            spec_path.unlink(missing_ok=True)
        else:
            publish(spec_path, previous_spec.decode('utf-8'))
        raise
    # Completion never starts pinentry: its snapshot is updated with the binary
    # by explicit apply, and the scripts only invoke Usage against this file.
    for name, content in pending.items():
        publish(directory / name, content)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination', type=Path, required=True)
    parser.add_argument('--usage', type=Path)
    args = parser.parse_args()
    try:
        generate(args.destination, args.usage)
    except (OSError, ValueError, subprocess.SubprocessError):
        parser.exit(1, 'CLI completion generation failed.\n')


if __name__ == '__main__':
    main()
