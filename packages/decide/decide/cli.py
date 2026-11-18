import argparse
import asyncio
from dataclasses import replace
import json
import math
import signal
import sys

from .config import load_config
from .core import DecisionError, Judge, OPERATION_HEADERS, operation_headers
from .ipc import default_socket, request, service_status
from .server import Service

try:
    from ._package import BACKEND, MODEL, LOADER, KEY_FILE
except ImportError:
    BACKEND, MODEL, LOADER, KEY_FILE = 'openrouter', 'typesafe/jev-1.14', None, None


def metadata_header(value):
    name, separator, content = value.partition(':')
    headers = operation_headers({name.strip(): content.strip()})
    if not separator or not headers or '\r' in value or '\n' in value:
        raise argparse.ArgumentTypeError('Use NAME: VALUE with ' + ', '.join(OPERATION_HEADERS))
    return next(iter(headers.items()))


def parser():
    p = argparse.ArgumentParser(prog='decide', allow_abbrev=False,
        description='Inspect models and submit requests to your private Decisions service.',
        epilog='Examples:\n  decide info\n  decide judge request.json\n  cat request.json | decide judge --json -',
        formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest='command')
    for name, help_text in [('judge', 'Submit a JSON request'), ('info', 'Show model and decision type information'),
                            ('serve', 'Run the service for a supervisor')]:
        command = sub.add_parser(name, help=help_text, allow_abbrev=False)
        command.add_argument('--config', help='TOML configuration file')
        command.add_argument('--socket', help='Unix socket path')
        command.add_argument('--timeout', type=float, help='Request timeout in seconds')
        command.add_argument('--model', help='Override the request model')
        if name in ('judge', 'info'):
            command.add_argument('--json', action='store_true', help='Print the complete result as JSON')
        if name == 'judge':
            command.add_argument('-H', '--header', type=metadata_header, action='append', default=[],
                                 help='Pass Decisions metadata as NAME: VALUE (repeatable)')
            command.add_argument('file', help='JSON request file, or - for stdin')
    return p


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
    service = Service(Judge(backend(config)), config.socket)
    await service.start()
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


async def run(args):
    config = load_config(backend=BACKEND, model=MODEL, socket=default_socket(),
                         openrouter_key_file=KEY_FILE, path=args.config)
    config = replace(config, **{name: getattr(args, name) for name in ('model', 'socket', 'timeout')
                                if getattr(args, name) is not None})
    if not math.isfinite(config.timeout) or config.timeout <= 0:
        raise ValueError('Timeout must be greater than zero')
    if args.command == 'serve':
        await serve(config)
        return
    if args.command == 'info':
        result = await inspect_model(config)
        if args.json:
            result['decision_types'] = [
                kind for kind, support in result['decision_types'].items() if support == 'supported'
            ]
            print(json.dumps(result, ensure_ascii=False))
        else:
            display_info(result)
        return
    if args.file == '-' and sys.stdin.isatty():
        raise ValueError('Provide a JSON request on stdin or pass a request file')
    try:
        if args.file == '-':
            document = json.load(sys.stdin)
        else:
            with open(args.file, encoding='utf-8') as source:
                document = json.load(source)
    except (json.JSONDecodeError, UnicodeDecodeError):
        raise ValueError('Request must contain valid JSON') from None
    if isinstance(document, dict):
        if args.model is not None:
            document['model'] = args.model
        else:
            document.setdefault('model', config.model)
    if sys.stderr.isatty() and not args.json:
        print('Waiting for the Decisions service…', file=sys.stderr)
    result = await request(config.socket, document, config.timeout, headers=dict(args.header))
    if args.json:
        print(json.dumps(result, ensure_ascii=False))
    else:
        display(result)


def main():
    p = parser()
    args = p.parse_args()
    if not args.command:
        print('Submit a Decisions request.\nExample: decide judge request.json\nRun decide --help for options.')
        return 0
    try:
        asyncio.run(run(args))
        return 0
    except KeyboardInterrupt:
        if args.command != 'judge':
            raise
        message = 'Request cancelled'
        if args.json:
            message = json.dumps({'error': {'code': 130, 'message': message}})
        print(message, file=sys.stderr)
        return 130
    except DecisionError as exc:
        if getattr(args, 'json', False):
            print(json.dumps(exc.body, ensure_ascii=False), file=sys.stderr)
            return 1
        message = exc.body.get('error', {}).get('message', 'Decisions request failed') if isinstance(exc.body, dict) else 'Decisions request failed'
        print(f'Error ({exc.status}): {message}', file=sys.stderr)
        return 1
    except (OSError, ValueError) as exc:
        # File paths and request content may contain sensitive data.
        print(f'Error: {exc}' if isinstance(exc, ValueError) else 'Error: Cannot read the file or start the service; check paths and permissions', file=sys.stderr)
        return 2

if __name__ == '__main__':
    sys.exit(main())
