"""Compose native T3 launch additions during explicit dotfiles application."""

import argparse
import copy
import json
import os
from pathlib import Path
import tempfile
import tomllib


CODEX_MARKER = '<dotfiles-t3-developer-instructions>'
CLAUDE_MARKER = '<dotfiles-preserved-claude-append>'
OVERRIDE = 'T3CODE_CODEX_LAUNCH_ARGS'
NATIVE_CONTROLS = {
    'codex': [['--disable', feature] for feature in
              ('multi_agent', 'multi_agent_v2', 'multi_agent_v2_dynamic_tools')],
    'claudeAgent': [['--disallowedTools=Agent']],
}


def environment_key(name):
    return name.upper() if os.name == 'nt' else name


def tokenize(value):
    """Match T3 0.1.7's tokenizeCliArgs, including its Windows path escaping."""
    if not isinstance(value, str):
        raise ValueError('Native launchArgs must be a string.')
    result, current, quote, quoted = [], '', None, False
    index = 0
    while index < len(value):
        char = value[index]
        following = value[index + 1] if index + 1 < len(value) else None
        if quote:
            if char == quote:
                quote, quoted = None, True
            elif char == '\\' and quote == '"' and following in ('"', '\\', '$', '`'):
                current += following
                index += 1
            else:
                current += char
        elif char in ('"', "'"):
            quote, quoted = char, True
        elif char.isspace():
            if current or quoted:
                result.append(current)
                current, quoted = '', False
        elif char == '\\' and following is not None and (following.isspace() or following in ('"', "'")):
            current += following
            index += 1
        else:
            current += char
        index += 1
    if current or quoted:
        result.append(current)
    return result


def join_args(arguments):
    return ' '.join('"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"' for value in arguments)


def flag_values(arguments, names):
    values = []
    for index, argument in enumerate(arguments):
        if argument in names:
            if index + 1 == len(arguments):
                raise ValueError('A native instruction option requires a value.')
            values.append(arguments[index + 1])
        else:
            for name in names:
                if argument.startswith(name + '='):
                    values.append(argument[len(name) + 1:])
    return values


def config_overrides(arguments):
    return flag_values(arguments, ('-c', '--config'))


def config_value(value):
    try:
        return tomllib.loads('value = ' + value)['value']
    except tomllib.TOMLDecodeError:
        # Codex likewise accepts a bare string when TOML parsing fails.
        return value


def instruction_config(home, provider, arguments, environment):
    config = provider.get('config', {})
    home_path = config.get('homePath') or environment.get('CODEX_HOME') or str(home / '.codex')
    if not isinstance(home_path, str):
        raise ValueError('Codex homePath must be a string.')
    if home_path == '~' or home_path.startswith(('~/', '~\\')):
        home_path = str(home / home_path[2:])
    path = Path(home_path) / 'config.toml'
    document = tomllib.loads(path.read_text(encoding='utf-8')) if path.is_file() else {}
    profiles = flag_values(arguments, ('--profile', '-p'))
    profile = profiles[-1] if profiles else document.get('profile')
    overrides = config_overrides(arguments)
    for value in overrides:
        key, separator, text = value.partition('=')
        if separator and key.strip() == 'profile':
            profile = config_value(text)
    if profile:
        document = {**document, **document.get('profiles', {}).get(profile, {})}
    developer = document.get('developer_instructions', '')
    for value in overrides:
        key, separator, text = value.partition('=')
        if separator and key.strip() == 'developer_instructions':
            developer = config_value(text)
    if not isinstance(developer, str):
        raise ValueError('Existing Codex developer instructions must be text.')
    return developer


def clean_owned(arguments, addition_file, controls=(), control_base=()):
    arguments = list(arguments)
    for contribution in reversed(controls):
        for index in range(len(arguments) - len(contribution), -1, -1):
            if arguments[index:index + len(contribution)] == contribution:
                arguments[index:index + len(contribution)] = control_base
                break
    result = []
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if argument in ('-c', '--config', '--append-system-prompt', '--append-system-prompt-file'):
            following = arguments[index + 1] if index + 1 < len(arguments) else ''
            if following == str(addition_file) or CODEX_MARKER in following or CLAUDE_MARKER in following:
                index += 2
                continue
        if CODEX_MARKER in argument or CLAUDE_MARKER in argument:
            index += 1
            continue
        result.append(argument)
        index += 1
    return result


def claude_controls(arguments):
    remaining, original, denied = [], [], []
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        name, separator, value = argument.partition('=')
        if name not in ('--disallowedTools', '--disallowed-tools'):
            remaining.append(argument)
            index += 1
            continue
        original.append(argument)
        if separator:
            denied.append(value)
        index += 1
        while index < len(arguments) and not arguments[index].startswith('-'):
            original.append(arguments[index])
            denied.append(arguments[index])
            index += 1
    controls = [['--disallowedTools=' + ','.join([*denied, 'Agent'])]]
    return remaining, original, controls


def read_mapping(path):
    if not path.is_file():
        return {}
    document = json.loads(path.read_text(encoding='utf-8'))
    if not isinstance(document, dict):
        raise ValueError('Native settings and launch state must be JSON objects.')
    return document


def publish(path, document):
    encoded = (json.dumps(document, ensure_ascii=False, indent=2) + '\n').encode('utf-8')
    if path.is_file() and path.read_bytes() == encoded:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(dir=path.parent, prefix='.instructions-')
    try:
        with os.fdopen(descriptor, 'wb') as output:
            output.write(encoded)
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def apply(destination, environment=None):
    environment = {environment_key(key): value for key, value in
                   (os.environ if environment is None else environment).items()}
    home = Path(destination)
    settings_path = home / '.t3/userdata/settings.json'
    state_path = settings_path.with_name('dotfiles-launch-state.json')
    settings = read_mapping(settings_path)
    providers = settings.get('providerInstances', {})
    if not isinstance(providers, dict):
        raise ValueError('T3 providerInstances must be an object.')
    state = read_mapping(state_path)
    if state and state.get('schema') != 1:
        raise ValueError('Unsupported private launch-state schema.')
    records = state.get('providers', {})
    next_records = {}
    changed = False
    for name, harness in (('codex', 'codex'), ('claudeAgent', 'claude'), ('pi', 'pi')):
        if name not in providers:
            continue
        provider = providers[name]
        if not isinstance(provider, dict) or not isinstance(provider.get('config', {}), dict):
            raise ValueError('Native provider configuration must be an object.')
        config = provider.setdefault('config', {})
        addition_file = settings_path.parent / 'instructions' / (harness + '.md')
        addition = addition_file.read_text(encoding='utf-8') if addition_file.is_file() else ''
        old = records.get(name, {})
        controls = NATIVE_CONTROLS.get(name, [])
        control_base = []
        if not addition.strip() and not old and not controls:
            continue
        current = config.get('launchArgs', '')
        if current == old.get('lastArgs'):
            base = old['baseArgs']
            had_args = old['hadArgs']
        else:
            base = join_args(clean_owned(tokenize(current), addition_file, old.get('controlArgs', []),
                                         old.get('controlBaseArgs', [])))
            had_args = 'launchArgs' in config
            if tokenize(base) == tokenize(current):
                base = current
        had_environment = 'environment' in provider
        base_environment = copy.deepcopy(provider.get('environment', []))
        if old and base_environment == old.get('lastEnvironment'):
            base_environment = old['baseEnvironment']
            had_environment = old['hadEnvironment']
        elif name == 'codex' and old and isinstance(base_environment, list):
            reserved = [entry for entry in base_environment if isinstance(entry, dict)
                        and environment_key(str(entry.get('name', ''))) == OVERRIDE]
            previous = [entry for entry in old.get('lastEnvironment', []) if environment_key(entry['name']) == OVERRIDE]
            if reserved == previous:
                base_environment = [entry for entry in base_environment if environment_key(str(entry.get('name', ''))) != OVERRIDE]
                for index, entry in enumerate(old['baseEnvironment']):
                    if environment_key(entry['name']) == OVERRIDE:
                        base_environment.insert(min(index, len(base_environment)), entry)
                had_environment = old['hadEnvironment'] or bool(base_environment)
        if not isinstance(base_environment, list) or any(
                not isinstance(entry, dict) or not isinstance(entry.get('name'), str) for entry in base_environment):
            raise ValueError('Native provider environment must contain named entries.')
        if not addition.strip() and not controls:
            if had_args:
                config['launchArgs'] = base
            else:
                config.pop('launchArgs', None)
            changed = True
            continue
        arguments = tokenize(base)
        if name == 'codex':
            effective = dict(environment)
            for entry in base_environment:
                if environment_key(entry['name']) in (OVERRIDE, 'CODEX_HOME'):
                    if not isinstance(entry.get('value'), str):
                        raise ValueError('Instruction environment overrides require text values during apply.')
                    effective[environment_key(entry['name'])] = entry['value']
            override = effective.get(OVERRIDE, '')
            if override.strip():
                arguments = clean_owned(tokenize(override), addition_file)
            arguments += [value for contribution in controls for value in contribution]
            if addition.strip():
                developer = instruction_config(home, provider, arguments, effective)
                combined = '\n\n'.join(value for value in (developer, CODEX_MARKER + '\n' + addition.rstrip()
                    + '\n</dotfiles-t3-developer-instructions>') if value)
                arguments += ['-c', 'developer_instructions=' + json.dumps(combined, ensure_ascii=False)]
            provider['environment'] = [entry for entry in base_environment if environment_key(entry['name']) != OVERRIDE]
            provider['environment'].append({'name': OVERRIDE, 'value': '', 'sensitive': False})
        elif name == 'claudeAgent':
            arguments, control_base, controls = claude_controls(arguments)
            arguments += [value for contribution in controls for value in contribution]
            files = flag_values(arguments, ('--append-system-prompt-file',)) if addition.strip() else []
            inline = flag_values(arguments, ('--append-system-prompt',)) if addition.strip() else []
            preserved = []
            if files:
                path = Path(files[-1])
                if not path.is_absolute():
                    raise ValueError('Existing Claude append files must be absolute for apply-time composition.')
                preserved.append(path.read_text(encoding='utf-8').removesuffix('\n').removesuffix('\r'))
            if inline:
                preserved.append(inline[-1])
            if addition.strip():
                arguments += ['--append-system-prompt-file', str(addition_file)]
            if preserved and addition.strip():
                arguments += ['--append-system-prompt', CLAUDE_MARKER + '\n' + '\n'.join(preserved)
                              + '\n</dotfiles-preserved-claude-append>']
        else:
            arguments += ['--append-system-prompt', str(addition_file)]
        config['launchArgs'] = join_args(arguments)
        next_records[name] = {'baseArgs': base, 'hadArgs': had_args, 'lastArgs': config['launchArgs'],
                              'controlArgs': controls,
                              'controlBaseArgs': control_base,
                              'baseEnvironment': base_environment, 'hadEnvironment': had_environment,
                              'lastEnvironment': copy.deepcopy(provider.get('environment', []))}
        changed = True
    if changed:
        had_state = state_path.is_file()
        publish(state_path, {'schema': 1, 'providers': next_records})
        try:
            publish(settings_path, settings)
        except OSError:
            if had_state:
                publish(state_path, state)
            else:
                state_path.unlink(missing_ok=True)
            raise


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination', required=True)
    args = parser.parse_args()
    try:
        apply(args.destination)
    except (OSError, ValueError, TypeError, KeyError):
        raise SystemExit('T3 instruction reconciliation failed. Check launch options, writable settings, and absolute append-file paths.') from None
