"""Resolve the authenticated Synthetic catalog into deterministic pi model pins."""

import argparse
from decimal import Decimal, InvalidOperation
import json
import math
import os
from pathlib import Path
import tempfile
from urllib.request import HTTPRedirectHandler, Request, build_opener


BASE_URL = 'https://api.synthetic.new/openai/v1'
MODELS_URL = BASE_URL + '/models'


class ModelLockError(ValueError):
    """Value-free diagnostic safe for CI logs."""


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def _text(value):
    if (not isinstance(value, str) or not value.strip() or len(value) > 1024
            or any(ord(character) < 32 or ord(character) == 127 for character in value)):
        raise ModelLockError('Invalid model text metadata.')
    return value


def _limit(value):
    if type(value) is not int or not 1 <= value <= 2**31 - 1:
        raise ModelLockError('Invalid model token limit.')
    return value


def _price(value):
    try:
        if not isinstance(value, str) or len(value) > 80:
            raise ValueError()
        price = Decimal(value.removeprefix('$'))
        result = float(price * 1_000_000)
        if not price.is_finite() or price < 0 or not math.isfinite(result):
            raise ValueError()
        return result
    except (ValueError, InvalidOperation, OverflowError):
        raise ModelLockError('Invalid model pricing metadata.') from None


def resolve_models(document):
    if not isinstance(document, dict) or not isinstance(document.get('data'), list) or not document['data']:
        raise ModelLockError('Expected a nonempty Synthetic model catalog.')
    models = []
    seen = set()
    for entry in document['data']:
        if not isinstance(entry, dict):
            raise ModelLockError('Invalid Synthetic model entry.')
        identifier = _text(entry.get('id'))
        if identifier in seen:
            raise ModelLockError('Duplicate Synthetic model identifier.')
        seen.add(identifier)
        inputs = entry.get('input_modalities')
        outputs = entry.get('output_modalities')
        features = entry.get('supported_features')
        if (not isinstance(inputs, list) or not inputs
                or any(not isinstance(value, str) or value not in ('text', 'image') for value in inputs)
                or len(inputs) != len(set(inputs))
                or outputs != ['text']
                or not isinstance(features, list) or any(not isinstance(value, str) for value in features)):
            raise ModelLockError('Unsupported or invalid model capability metadata.')
        context = _limit(entry.get('context_length'))
        maximum = _limit(entry.get('max_output_length'))
        if maximum > context:
            raise ModelLockError('Model output limit exceeds its context window.')
        pricing = entry.get('pricing')
        if not isinstance(pricing, dict) or not all(field in pricing for field in ('prompt', 'completion')):
            raise ModelLockError('Expected model pricing metadata.')
        model = {
            'id': identifier,
            'name': _text(entry.get('display_name') or entry.get('name') or identifier),
            'reasoning': 'reasoning' in features,
            'input': [kind for kind in ('text', 'image') if kind in inputs],
            'cost': {target: _price(pricing.get(source, '0')) for source, target in (
                ('prompt', 'input'), ('completion', 'output'),
                ('input_cache_reads', 'cacheRead'), ('input_cache_writes', 'cacheWrite'))},
            'contextWindow': context,
            'maxTokens': maximum,
        }
        models.append(model)
    return {'syntheticModelLocks': {'provider': 'synthetic', 'baseUrl': BASE_URL,
                                    'api': 'openai-completions',
                                    'models': sorted(models, key=lambda model: model['id'])}}


def fetch_models(key, *, opener=None):
    if not isinstance(key, str) or not key or any(character in key for character in '\r\n\0'):
        raise ModelLockError('Provide SYNTHETIC_API_KEY for authenticated model discovery.')
    request = Request(MODELS_URL, headers={'Authorization': 'Bearer ' + key,
                      'Accept': 'application/json', 'User-Agent': 'dotfiles-model-lock'})
    try:
        open_request = opener or build_opener(NoRedirect()).open
        with open_request(request, timeout=30) as response:
            content = response.read(2_000_001)
        if len(content) > 2_000_000:
            raise ValueError()
        return json.loads(content)
    except Exception:
        # Response bodies, headers, and transport exceptions can contain secrets.
        raise ModelLockError('Synthetic model discovery failed; prior model pins retained.') from None


def validate_lock(document):
    if not isinstance(document, dict) or set(document) != {'syntheticModelLocks'}:
        raise ModelLockError('Invalid Synthetic model lock.')
    catalog = document['syntheticModelLocks']
    if (not isinstance(catalog, dict) or set(catalog) != {'provider', 'baseUrl', 'api', 'models'}
            or catalog['provider'] != 'synthetic' or catalog['baseUrl'] != BASE_URL
            or catalog['api'] != 'openai-completions'
            or not isinstance(catalog['models'], list) or not catalog['models']):
        raise ModelLockError('Invalid Synthetic model lock provider.')
    seen = set()
    fields = {'id', 'name', 'reasoning', 'input', 'cost', 'contextWindow', 'maxTokens'}
    for model in catalog['models']:
        if not isinstance(model, dict) or set(model) != fields:
            raise ModelLockError('Invalid Synthetic locked model fields.')
        identifier = _text(model['id'])
        _text(model['name'])
        if identifier in seen:
            raise ModelLockError('Duplicate Synthetic locked model identifier.')
        seen.add(identifier)
        inputs = model['input']
        if (type(model['reasoning']) is not bool or not isinstance(inputs, list) or not inputs
                or any(not isinstance(value, str) or value not in ('text', 'image') for value in inputs)
                or len(inputs) != len(set(inputs))
                or _limit(model['maxTokens']) > _limit(model['contextWindow'])):
            raise ModelLockError('Invalid Synthetic locked model capabilities.')
        costs = model['cost']
        if (not isinstance(costs, dict) or set(costs) != {'input', 'output', 'cacheRead', 'cacheWrite'}
                or any(type(value) not in (int, float) or not math.isfinite(value) or value < 0
                       for value in costs.values())):
            raise ModelLockError('Invalid Synthetic locked model costs.')
    return document


def update_lock(path, document):
    content = (json.dumps(resolve_models(document), ensure_ascii=False, sort_keys=True,
                          indent=2, allow_nan=False) + '\n').encode('utf-8')
    path = Path(path)
    if path.exists() and path.read_bytes() == content:
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(content)
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return True


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path,
                        default=Path(__file__).resolve().parents[1] / 'home/.chezmoidata/synthetic-model-lock.json')
    inputs = parser.add_mutually_exclusive_group()
    inputs.add_argument('--token-file', type=Path, help='External local credential input; retained after use')
    inputs.add_argument('--check', type=Path, help='Validate a candidate lock without credentials or network')
    args = parser.parse_args(argv)
    try:
        if args.check:
            validate_lock(json.loads(args.check.read_text(encoding='utf-8')))
            print('Synthetic model candidate validated.')
            return 0
        key = (args.token_file.read_text(encoding='utf-8-sig').removesuffix('\n').removesuffix('\r')
               if args.token_file else os.environ.get('SYNTHETIC_API_KEY'))
        changed = update_lock(args.output, fetch_models(key))
    except Exception:
        print('Synthetic model lock refresh failed; prior model pins retained.')
        return 1
    print('Updated Synthetic model pins.' if changed else 'Synthetic model pins are unchanged.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
