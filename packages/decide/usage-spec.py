"""Export the Click command tree for Usage shell completion."""

import json

import click

from decide.cli import cli


def quote(value):
    return json.dumps(value, ensure_ascii=False)


def emit_command(command, name, parent=None, indent=''):
    with click.Context(command, info_name=name, parent=parent, **command.context_settings) as context:
        for parameter in command.get_params(context):
            if isinstance(parameter, click.Argument):
                argument = f'<{parameter.name}>' if parameter.required else f'[{parameter.name}]'
                print(f'{indent}arg {quote(argument)}')
                continue
            if parameter.hidden:
                continue

            flags = ' '.join(parameter.opts)
            if not parameter.is_flag:
                flags += f' <{parameter.name}>'
            properties = [f'help={quote(parameter.help)}'] if parameter.help else []
            if parameter.secondary_opts:
                properties.append(f'negate={quote(parameter.secondary_opts[0])}')
            if parameter.multiple:
                properties.append('var=#true')
            flag = ' '.join(['flag', quote(flags), *properties])
            if not parameter.is_flag and not isinstance(parameter.type, click.Path):
                flag += ' { complete type="none"; }'
            print(f'{indent}{flag}')

        if isinstance(command, click.Group):
            for subcommand in command.list_commands(context):
                child = command.get_command(context, subcommand)
                print(f'{indent}cmd {quote(subcommand)} help={quote(child.get_short_help_str())} {{')
                emit_command(child, subcommand, context, indent + '    ')
                print(f'{indent}}}')


if __name__ == '__main__':
    print('bin "decide"')
    emit_command(cli, 'decide')
