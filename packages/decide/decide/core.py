from typing import Any, Mapping, Protocol

OPERATION_HEADERS = ('HTTP-Referer', 'X-OpenRouter-Title', 'X-OpenRouter-Categories', 'x-session-id')


def operation_headers(headers):
    names = {name.lower(): name for name in OPERATION_HEADERS}
    return {names[name.lower()]: value for name, value in (headers or {}).items()
            if name.lower() in names}


class DecisionError(Exception):
    """An HTTP status and Decisions service error document."""

    def __init__(self, status: int, body: Any):
        self.status = status
        self.body = body
        super().__init__(f'Decisions request failed ({status})')


def error(status: int, message: str) -> DecisionError:
    return DecisionError(status, {'error': {'code': status, 'message': message}})


class Backend(Protocol):
    """Honor the requested model or raise a capability error; never substitute it."""

    async def judge(self, request: Mapping[str, Any], *, headers=None) -> dict[str, Any]: ...


class Judge:
    def __init__(self, backend: Backend):
        self.backend = backend

    async def judge(self, request: Mapping[str, Any], *, headers=None) -> dict[str, Any]:
        from .schema import validate_request, validate_response

        validate_request(request)
        response = await self.backend.judge(request, headers=operation_headers(headers))
        validate_response(response)
        return response
