from dataclasses import replace
import json
import math
import sys

import click

try:
    from ._package import BACKEND, MODEL, LOADER, KEY_FILE
except ImportError:
    BACKEND, MODEL, LOADER, KEY_FILE = 'openrouter', 'typesafe/jev-1.14', None, None


def metadata_header(value):
    from .core import OPERATION_HEADERS, operation_headers

    name, separator, content = value.partition(':')
    headers = operation_headers({name.strip(): content.strip()})
    if not separator or not headers or '\r' in value or '\n' in value:
        raise click.BadParameter('Use NAME: VALUE with ' + ', '.join(OPERATION_HEADERS))
    return next(iter(headers.items()))


def connection_options(command):
    options = (
        click.option('--config', type=click.Path(readable=False), help='Read settings from this TOML file.'),
        click.option('--socket', type=click.Path(readable=False), help='Use this Unix socket path.'),
        click.option('--timeout', type=float, metavar='SECONDS', help='Override the request timeout.'),
        click.option('--model', help='Override the request model.'),
    )
    for option in reversed(options):
        command = option(command)
    return command


@click.group(invoke_without_command=True, context_settings={'help_option_names': ['-h', '--help']})
@click.pass_context
def cli(ctx):
    """Inspect models and submit requests to your private Decisions service.

    \b
    Examples:
      decide info
      decide judge request.json
      cat request.json | decide judge --json -
    """
    if ctx.invoked_subcommand is None:
        click.echo(ctx.get_help())


@cli.command('judge')
@click.argument('file', type=click.Path(readable=False, allow_dash=True))
@click.option('--json', 'json_output', is_flag=True, help='Print the full response as JSON.')
@click.option('-H', '--header', 'headers', multiple=True, type=metadata_header, metavar='NAME: VALUE',
              help='Send a Decisions metadata header. Repeat for multiple headers.')
@connection_options
def judge_command(file, json_output, headers, **overrides):
    """Submit a JSON request. Use - for standard input."""
    return run_command(
        lambda config: judge_request(config, file, dict(headers), overrides['model'], json_output),
        overrides, json_output=json_output, cancel_request=True,
    )


@cli.command('info')
@click.option('--json', 'json_output', is_flag=True, help='Print model information as JSON.')
@connection_options
def info_command(json_output, **overrides):
    """Show model and decision type information."""
    return run_command(lambda config: print_model(config, json_output), overrides, json_output=json_output)


@cli.command('serve')
@click.option('--preload/--no-preload', default=None, help='Load the local model before accepting requests.')
@connection_options
def serve_command(**overrides):
    """Run the service in the foreground."""
    return run_command(serve, overrides)


def backend(config):
    if config.backend == 'mlx':
        from .mlx import MLX
        return MLX(LOADER)
    if config.backend == 'cuda':
        from .cuda import CUDA
        return CUDA(LOADER)
    from .openrouter import OpenRouter
    return OpenRouter(key_file=config.openrouter_key_file, timeout=config.timeout)


async def serve(config):
    import asyncio
    import signal

    from .core import Judge
    from .server import Service

    service = Service(Judge(backend(config)), config.socket)
    await service.start(preload=config.preload)
    stopped = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stopped.set)
    print(f'Decisions service listening on {config.socket}', file=sys.stderr)
    try:
        await stopped.wait()
    finally:
        await service.close()


def display(result):
    for name, answer in result['answers'].items():
        kind = answer['type']
        value = answer.get(kind, answer.get('reason', ''))
        if isinstance(value, (dict, list)):
            value = json.dumps(value, ensure_ascii=False)
        print(f'{name} ({kind}): {value}')


async def inspect_model(config):
    from .ipc import service_status

    if not isinstance(config.model, str) or not config.model.strip():
        raise ValueError('Model must be a non-empty string')
    status = await service_status(config.socket, min(config.timeout, 2))
    result = {'model': config.model, 'backend_source': 'service' if status else 'package'}
    if status is None:
        status = {'backend': config.backend}
        if config.backend != 'openrouter':
            status = backend(config).packaged_status()
    result.update(status)

    if status['backend'] == 'openrouter':
        from .openrouter import BOX_MODELS, ROUTED_DECISION_TYPES, model_metadata

        catalog_status, remote_model = await model_metadata(config.model, config.timeout)
        supported = ROUTED_DECISION_TYPES if catalog_status == 'matched' else ()
        if remote_model is not None:
            result['remote_model'] = remote_model
            # OpenRouter documents Box for this model in its Multimodal Decisions guide.
            if remote_model.get('id') in BOX_MODELS:
                supported += ('box',)
        result['catalog_status'] = catalog_status
        default_support = 'unknown'
    else:
        from .local import LOCAL_DECISION_TYPES

        supported = LOCAL_DECISION_TYPES if config.model == status['local_model']['id'] else ()
        default_support = 'unsupported'

    result['decision_types'] = {kind: 'supported' if kind in supported else default_support
                                for kind in ('noul', 'choice', 'score', 'box')}
    return result


def display_info(result):
    print(f"Model: {result['model']}")
    print(f"Backend: {result['backend']} ({result['backend_source']})")
    if local := result.get('local_model'):
        print(f"Bundled model: {local['id']}")
        print(f"Revision: {local['revision']}")
        print(f"Load state: {local['load_state']}")
        if result['model'] != local['id']:
            print('The selected model is unavailable on this backend.')
    else:
        catalog = result['catalog_status']
        print('OpenRouter catalog: ' + catalog.replace('_', ' '))
        if remote := result.get('remote_model'):
            if remote.get('id') and remote['id'] != result['model']:
                print(f"Catalog model ID: {remote['id']}")
            if 'name' in remote:
                print(f"Model name: {remote['name']}")
            if 'context_length' in remote:
                print(f"Context length: {remote['context_length']} tokens")
    print('Decision types: ' + ', '.join(f'{kind} ({support})'
                                         for kind, support in result['decision_types'].items()))


def command_config(config, **overrides):
    from .config import load_config
    from .ipc import default_socket

    config = load_config(backend=BACKEND, model=MODEL, socket=default_socket(),
                         openrouter_key_file=KEY_FILE, path=config)
    config = replace(config, **{name: value for name, value in overrides.items() if value is not None})
    if not math.isfinite(config.timeout) or config.timeout <= 0:
        raise ValueError('Timeout must be greater than zero')
    return config


async def print_model(config, json_output):
    result = await inspect_model(config)
    if json_output:
        result['decision_types'] = [
            kind for kind, support in result['decision_types'].items() if support == 'supported'
        ]
        print(json.dumps(result, ensure_ascii=False))
    else:
        display_info(result)


async def judge_request(config, file, headers, model_override, json_output):
    from .ipc import request

    if file == '-' and sys.stdin.isatty():
        raise ValueError('Provide a JSON request on stdin or pass a request file')
    try:
        if file == '-':
            document = json.load(sys.stdin)
        else:
            with open(file, encoding='utf-8') as source:
                document = json.load(source)
    except (json.JSONDecodeError, UnicodeDecodeError):
        raise ValueError('Request must contain valid JSON') from None
    if isinstance(document, dict):
        if model_override is not None:
            document['model'] = model_override
        else:
            document.setdefault('model', config.model)
    if sys.stderr.isatty() and not json_output:
        print('Waiting for the Decisions service…', file=sys.stderr)
    result = await request(config.socket, document, config.timeout, headers=headers)
    if json_output:
        print(json.dumps(result, ensure_ascii=False))
    else:
        display(result)


def run_command(operation, overrides, *, json_output=False, cancel_request=False):
    import asyncio

    from .core import DecisionError

    try:
        asyncio.run(operation(command_config(**overrides)))
        return 0
    except KeyboardInterrupt:
        if not cancel_request:
            raise
        message = 'Request cancelled'
        if json_output:
            message = json.dumps({'error': {'code': 130, 'message': message}})
        print(message, file=sys.stderr)
        return 130
    except DecisionError as exc:
        if json_output:
            print(json.dumps(exc.body, ensure_ascii=False), file=sys.stderr)
            return 1
        message = exc.body.get('error', {}).get('message', 'Decisions request failed') if isinstance(exc.body, dict) else 'Decisions request failed'
        print(f'Error ({exc.status}): {message}', file=sys.stderr)
        return 1
    except (OSError, ValueError) as exc:
        # File paths and request content may contain sensitive data.
        print(f'Error: {exc}' if isinstance(exc, ValueError) else 'Error: Cannot read the file or start the service; check paths and permissions', file=sys.stderr)
        return 2


def main(args=None):
    try:
        return cli.main(args, prog_name='decide', standalone_mode=False) or 0
    except click.ClickException as exc:
        exc.show()
        return exc.exit_code
    except click.Abort:
        return 130


if __name__ == '__main__':
    sys.exit(main())
