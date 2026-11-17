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
