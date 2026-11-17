"""Validate against the vendored OpenRouter Decisions operation."""

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
    if next(_REQUEST.iter_errors(document), None) is not None:
        raise error(400, 'Invalid Decisions request')


def validate_response(document):
    if next(_RESPONSE.iter_errors(document), None) is not None:
        raise error(502, 'Invalid Decisions response from backend')
