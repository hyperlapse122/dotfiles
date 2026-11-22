import json
import sys

import click

try:
    from ._package import LOADER
except ImportError:
    LOADER = None


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


def focused_options(command):
    command = click.option('--json', 'json_output', is_flag=True, help='Print the full response as JSON.')(command)
    command = click.option('-H', '--header', 'headers', multiple=True, type=metadata_header,
                           metavar='NAME: VALUE', help='Send a Decisions metadata header.')(command)
    return connection_options(command)


def focused(kind, state, question, json_output, headers, overrides):
    document = {'state': state, 'questions': {'result': {'type': kind, **question}}}
    document['model'] = overrides['model']

    async def submit(config):
        if document['model'] is None:
            document['model'] = config.model
        await submit_request(config, document, dict(headers), json_output)

    return run_command(submit, overrides, json_output=json_output, cancel_request=True)


@cli.command('noul')
@click.argument('instructions')
@click.option('--state', required=True, help='Context for the judgment.')
@focused_options
def noul_command(state, instructions, json_output, headers, **overrides):
    """Estimate the probability of a statement."""
    return focused('noul', state, {'instructions': instructions}, json_output, headers, overrides)


@cli.command('choice')
@click.option('--state', required=True, help='Context for the judgment.')
@click.option('--alternative', 'alternatives', type=(str, str), multiple=True, required=True,
              metavar='NAME CRITERION', help='Name an alternative and its criterion. Repeat for each.')
@focused_options
def choice_command(state, alternatives, json_output, headers, **overrides):
    """Choose among named alternatives."""
    if len(dict(alternatives)) != len(alternatives):
        raise click.BadParameter('Alternative names must be unique', param_hint='--alternative')
    return focused('choice', state, {'criteria': dict(alternatives)}, json_output, headers, overrides)


@cli.command('score')
@click.option('--state', required=True, help='Context for the judgment.')
@click.option('--level', 'levels', multiple=True, required=True, help='Add a level in order from low to high.')
@focused_options
def score_command(state, levels, json_output, headers, **overrides):
    """Score against ordered levels."""
    return focused('score', state, {'criteria': list(levels)}, json_output, headers, overrides)


@cli.command('box')
@click.argument('instructions')
@click.option('--image', required=True, help='Image URL or data URL.')
@focused_options
def box_command(image, instructions, json_output, headers, **overrides):
    """Find a bounding box in an image."""
    state = [{'type': 'image_url', 'image_url': {'url': image}}]
    return focused('box', state, {'instructions': instructions}, json_output, headers, overrides)


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
        if kind == 'score' and 'legend' in answer:
            print('  legend: ' + json.dumps(answer['legend'], ensure_ascii=False))


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
    await submit_request(config, document, headers, json_output)


async def submit_request(config, document, headers, json_output):
    from .ipc import request

    if sys.stderr.isatty() and not json_output:
        print('Waiting for the Decisions service…', file=sys.stderr)
    result = await request(config.socket, document, config.timeout, headers=headers)
    if json_output:
        print(json.dumps(result, ensure_ascii=False))
    else:
        display(result)


def run_command(operation, overrides, *, json_output=False, cancel_request=False):
    import asyncio

    from .config import command_config
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
