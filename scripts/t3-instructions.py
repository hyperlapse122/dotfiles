"""Compose native T3 launch additions during explicit dotfiles application."""

import argparse
import copy
import json
import os
from pathlib import Path
import tempfile


CLAUDE_MARKER = '<dotfiles-preserved-claude-append>'
NATIVE_CONTROLS = {'pi': [['--approve']]}
CLAUDE_DEPTH = 'CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH'


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


def clean_owned(arguments, addition_file):
    result = []
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if argument in ('--append-system-prompt', '--append-system-prompt-file'):
            following = arguments[index + 1] if index + 1 < len(arguments) else ''
            if following == str(addition_file) or CLAUDE_MARKER in following:
                index += 2
                continue
        if CLAUDE_MARKER in argument:
            index += 1
            continue
        result.append(argument)
        index += 1
    return result


def restore_arguments(current, old, addition_file):
    arguments = tokenize(current)
    previous = tokenize(old.get('lastArgs', ''))
    matches = [i for i in range(len(arguments) - len(previous) + 1)
               if previous and arguments[i:i + len(previous)] == previous]
    if len(matches) == 1:
        index = matches[0]
        arguments[index:index + len(previous)] = tokenize(old['baseArgs'])
    else:
        # A control duplicated in the baseline or current arguments has no
        # unambiguous owner once the recorded launch has been edited.
        baseline = tokenize(old.get('baseArgs', ''))
        for control in old.get('controlArgs', []):
            locations = [i for i in range(len(arguments) - len(control) + 1)
                         if arguments[i:i + len(control)] == control]
            in_base = any(baseline[i:i + len(control)] == control
                          for i in range(len(baseline) - len(control) + 1))
            if len(locations) == 1 and not in_base:
                index = locations[0]
                arguments[index:index + len(control)] = old.get('controlBaseArgs', [])
    return clean_owned(arguments, addition_file)


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


def apply(destination, hidden_models=()):
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
    for name, harness in (('claudeAgent', 'claude'), ('pi', 'pi')):
        if name not in providers:
            continue
        provider = providers[name]
        if not isinstance(provider, dict) or not isinstance(provider.get('config', {}), dict):
            raise ValueError('Native provider configuration must be an object.')
        config = provider.get('config', {})
        addition_file = settings_path.parent / 'instructions' / (harness + '.md')
        addition = addition_file.read_text(encoding='utf-8') if addition_file.is_file() else ''
        old = records.get(name, {})
        controls = NATIVE_CONTROLS.get(name, [])
        if name == 'claudeAgent':
            entries = provider.get('environment', [])
            if not isinstance(entries, list) or any(not isinstance(e, dict) or not isinstance(e.get('name'), str) for e in entries):
                raise ValueError('Native provider environment must contain named entries.')
            # Claude treats an empty depth as unset, so it uses its default
            # instead of the standalone cap inherited from the shell.
            if not any(environment_key(e['name']) == CLAUDE_DEPTH for e in entries):
                provider['environment'] = entries + [{'name': CLAUDE_DEPTH, 'value': '', 'sensitive': False}]
                changed = True
        if not addition.strip() and not old and not controls:
            current = config.get('launchArgs', '')
            if not isinstance(current, str) or (str(addition_file) not in current and CLAUDE_MARKER not in current):
                continue
            arguments = tokenize(current)
            cleaned = clean_owned(arguments, addition_file)
            if cleaned != arguments:
                if cleaned:
                    config['launchArgs'] = join_args(cleaned)
                else:
                    config.pop('launchArgs', None)
                provider['config'] = config
                changed = True
            continue
        current = config.get('launchArgs', '')
        if current == old.get('lastArgs'):
            base = old['baseArgs']
            had_args = old['hadArgs']
        else:
            base = join_args(restore_arguments(current, old, addition_file))
            had_args = 'launchArgs' in config
            if tokenize(base) == tokenize(current):
                base = current
        had_environment = 'environment' in provider
        base_environment = copy.deepcopy(provider.get('environment', []))
        if old and base_environment == old.get('lastEnvironment'):
            base_environment = old['baseEnvironment']
            had_environment = old['hadEnvironment']
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
        if name == 'claudeAgent':
            files = flag_values(arguments, ('--append-system-prompt-file',))
            inline = flag_values(arguments, ('--append-system-prompt',))
            preserved = []
            if files:
                path = Path(files[-1])
                if not path.is_absolute():
                    raise ValueError('Existing Claude append files must be absolute for apply-time composition.')
                preserved.append(path.read_text(encoding='utf-8').removesuffix('\n').removesuffix('\r'))
            if inline:
                preserved.append(inline[-1])
            arguments += ['--append-system-prompt-file', str(addition_file)]
            if preserved:
                arguments += ['--append-system-prompt', CLAUDE_MARKER + '\n' + '\n'.join(preserved)
                              + '\n</dotfiles-preserved-claude-append>']
        else:
            controls = [control for control in controls if control[0] not in arguments]
            arguments += [value for contribution in controls for value in contribution]
            if addition.strip():
                arguments += ['--append-system-prompt', str(addition_file)]
        provider['config'] = config
        config['launchArgs'] = join_args(arguments)
        next_records[name] = {'baseArgs': base, 'hadArgs': had_args, 'lastArgs': config['launchArgs'],
                              'controlArgs': controls,
                              'baseEnvironment': base_environment, 'hadEnvironment': had_environment,
                              'lastEnvironment': copy.deepcopy(provider.get('environment', []))}
        changed = True
    client_path = settings_path.with_name('client-settings.json')
    client = read_mapping(client_path)
    preferences = client.setdefault('providerModelPreferences', {}).setdefault('pi', {})
    hidden = preferences.get('hiddenModels', [])
    if not isinstance(hidden, list):
        raise ValueError('Pi hiddenModels must be a list.')
    missing = [model for model in dict.fromkeys(('default', *hidden_models)) if model not in hidden]
    if missing:
        preferences['hiddenModels'] = hidden + missing
        publish(client_path, client)
    if changed:
        had_state = state_path.is_file()
        try:
            publish(state_path, {'schema': 1, 'providers': next_records})
            publish(settings_path, settings)
        except (OSError, KeyboardInterrupt):
            # An interruption can arrive after the settings rename as well.
            # Keep the new ownership record only if those settings are live.
            try:
                settings_written = read_mapping(settings_path) == settings
            except (OSError, ValueError):
                settings_written = False
            if not settings_written:
                if had_state:
                    publish(state_path, state)
                else:
                    state_path.unlink(missing_ok=True)
            raise


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination', required=True)
    parser.add_argument('--hide-model', action='append', default=[])
    args = parser.parse_args()
    try:
        apply(args.destination, hidden_models=args.hide_model)
    except (OSError, ValueError, TypeError, KeyError, AttributeError):
        raise SystemExit('T3 instruction reconciliation failed. Check launch options, writable settings, and absolute append-file paths.') from None
