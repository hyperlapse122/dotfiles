import json
from pathlib import Path

from jsonschema import Draft202012Validator

from .core import error

_DOCUMENT = json.loads((Path(__file__).parent / 'schemas' / 'decisions.json').read_text())


def _validator(name):
    return Draft202012Validator({
        '$ref': f'#/components/schemas/{name}',
        'components': _DOCUMENT['components'],
    })


_REQUEST = _validator('DecisionsRequest')
_RESPONSE = _validator('DecisionsResponse')


def validate_request(document):
    if not _REQUEST.is_valid(document):
        raise error(400, 'Invalid Decisions request')


def validate_response(document):
    if not _RESPONSE.is_valid(document):
        raise error(502, 'Invalid Decisions response from backend')


def tool_input_schema():
    schemas = _DOCUMENT['components']['schemas']
    definitions = {}
    prefix = '#/components/schemas/'

    def convert(value):
        if isinstance(value, list):
            return [convert(item) for item in value]
        if not isinstance(value, dict):
            return value
        result = {key: convert(item) for key, item in value.items() if key != 'discriminator'}
        ref = result.get('$ref')
        if isinstance(ref, str) and ref.startswith(prefix):
            name = ref.removeprefix(prefix)
            if name not in definitions:
                definitions[name] = {}
                definitions[name].update(convert(schemas[name]))
            result['$ref'] = f'#/$defs/{name}'
        return result

    schema = convert(schemas['DecisionsRequest'])
    schema['required'].remove('model')
    schema['$defs'] = definitions
    return schema
