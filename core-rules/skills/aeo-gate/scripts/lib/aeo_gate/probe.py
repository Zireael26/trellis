from __future__ import annotations

import http.client
import ipaddress
import json
import re
import ssl
import socket
from dataclasses import asdict, dataclass
from datetime import UTC, datetime
from pathlib import Path
from urllib.parse import ParseResult, urljoin, urlparse

from .capture import atomic_write
from .models import canonical_json

MAX_RESPONSE_BYTES = 2 * 1024 * 1024
_SECRET_JSON_VALUE = re.compile(
    rb"""(?i)(["'](?:token|api[_-]?key|secret|password|authorization)["']\s*:\s*["'])([^"']+)(["'])"""
)
_SECRET_HTML_ATTRIBUTE = re.compile(
    rb"""(?i)(\b(?:data-)?(?:token|api-key|apikey|secret|password|authorization)\s*=\s*["'])([^"']+)(["'])"""
)
USER_AGENTS = {
    "gptbot": "GPTBot/1.0",
    "claudebot": "ClaudeBot/1.0",
    "perplexitybot": "PerplexityBot/1.0",
    "chatgpt-user": "ChatGPT-User/1.0",
}


class _PinnedHTTPConnection(http.client.HTTPConnection):
    def __init__(self, host: str, address: str, port: int, *, timeout: float) -> None:
        super().__init__(host, port, timeout=timeout)
        self._address = address

    def connect(self) -> None:
        self.sock = socket.create_connection(
            (self._address, self.port),
            timeout=self.timeout,
        )


class _PinnedHTTPSConnection(http.client.HTTPConnection):
    def __init__(self, host: str, address: str, port: int, *, timeout: float) -> None:
        super().__init__(host, port, timeout=timeout)
        self._address = address
        self._ssl_context = ssl.create_default_context()

    def connect(self) -> None:
        plain_socket = socket.create_connection(
            (self._address, self.port),
            timeout=self.timeout,
        )
        self.sock = self._ssl_context.wrap_socket(
            plain_socket,
            server_hostname=self.host,
        )


@dataclass(frozen=True)
class ProbeObservation:
    agent: str
    user_agent: str
    requested_url: str
    final_url: str
    status: int
    headers: dict[str, str]
    fetched_at: str
    body_bytes: int
    truncated: bool
    redirects: tuple[dict[str, str | int], ...] = ()
    error: str = ""


def fetch(
    url: str, *, agent: str, timeout: float, max_bytes: int = MAX_RESPONSE_BYTES
) -> tuple[ProbeObservation, bytes]:
    parsed, addresses = _validate_public_url(url)
    expected_host = parsed.hostname
    assert expected_host is not None
    user_agent = USER_AGENTS.get(agent, agent)
    redirects: list[dict[str, str | int]] = []
    current_url = url
    previous_scheme = parsed.scheme
    try:
        for _ in range(11):
            parsed, addresses = _validate_public_url(
                current_url, expected_host=expected_host
            )
            if previous_scheme == "https" and parsed.scheme != "https":
                raise ValueError("probe redirect attempted an HTTPS downgrade")
            previous_scheme = parsed.scheme
            status, headers, body = _request_pinned(
                parsed,
                addresses,
                user_agent=user_agent,
                timeout=timeout,
                max_bytes=max_bytes,
            )
            location = headers.get("location")
            if status in {301, 302, 303, 307, 308} and location:
                redirected_url = urljoin(current_url, location)
                _validate_public_url(redirected_url, expected_host=expected_host)
                redirects.append(
                    {
                        "status": status,
                        "from": current_url,
                        "to": redirected_url,
                        "observed_at": _now(),
                    }
                )
                current_url = redirected_url
                continue
            observation = ProbeObservation(
                agent=agent,
                requested_url=url,
                user_agent=user_agent,
                final_url=current_url,
                status=status,
                headers=_safe_headers(headers.items()),
                fetched_at=_now(),
                body_bytes=min(len(body), max_bytes),
                truncated=len(body) > max_bytes,
                redirects=tuple(redirects),
            )
            return observation, body[:max_bytes]
        raise ValueError("probe exceeded the redirect limit")
    except (OSError, http.client.HTTPException, ValueError) as exc:
        return (
            ProbeObservation(
                agent=agent,
                user_agent=user_agent,
                requested_url=url,
                final_url=current_url,
                status=0,
                headers={},
                fetched_at=_now(),
                body_bytes=0,
                truncated=False,
                error=str(exc),
                redirects=tuple(redirects),
            ),
            b"",
        )


def _request_pinned(
    parsed: ParseResult,
    addresses: tuple[str, ...],
    *,
    user_agent: str,
    timeout: float,
    max_bytes: int,
) -> tuple[int, dict[str, str], bytes]:
    host = parsed.hostname
    assert host is not None
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    target = parsed.path or "/"
    last_error: Exception | None = None
    for address in addresses:
        connection: http.client.HTTPConnection
        if parsed.scheme == "https":
            connection = _PinnedHTTPSConnection(host, address, port, timeout=timeout)
        else:
            connection = _PinnedHTTPConnection(host, address, port, timeout=timeout)
        try:
            connection.request(
                "GET",
                target,
                headers={
                    "User-Agent": user_agent,
                    "Accept": "text/html,application/xhtml+xml",
                },
            )
            response = connection.getresponse()
            body = response.read(max_bytes + 1)
            headers = {
                str(name).lower(): str(value) for name, value in response.getheaders()
            }
            return response.status, headers, body
        except (OSError, http.client.HTTPException) as exc:
            last_error = exc
        finally:
            connection.close()
    if last_error is None:
        raise OSError("probe host resolved without usable addresses")
    raise last_error


def write_probe(
    run_dir: Path, observation: ProbeObservation, body: bytes | None
) -> tuple[Path, Path | None]:
    raw_dir = run_dir / "raw"
    metadata_path = raw_dir / f"probe-{observation.agent}.json"
    atomic_write(metadata_path, canonical_json(asdict(observation)))
    if body is None:
        return metadata_path, None
    body_path = raw_dir / f"probe-{observation.agent}.html"
    atomic_write(body_path, _sanitize_body(body))
    return metadata_path, body_path


def read_probe(path: Path) -> ProbeObservation:
    return ProbeObservation(**json.loads(path.read_text(encoding="utf-8")))


def _safe_headers(items) -> dict[str, str]:
    excluded = {"set-cookie", "authorization", "proxy-authorization"}
    return {
        str(name).lower(): str(value)
        for name, value in items
        if str(name).lower() not in excluded
    }


def _sanitize_body(body: bytes) -> bytes:
    redacted = _SECRET_JSON_VALUE.sub(rb"\1<REDACTED>\3", body)
    return _SECRET_HTML_ATTRIBUTE.sub(rb"\1<REDACTED>\3", redacted)


def _validate_public_url(
    url: str, *, expected_host: str | None = None
) -> tuple[ParseResult, tuple[str, ...]]:
    parsed = urlparse(url)
    if (
        parsed.scheme not in {"http", "https"}
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or parsed.params
    ):
        raise ValueError(
            "probe URL must be an absolute credential-free HTTP(S) URL without a query"
        )
    if (
        expected_host is not None
        and parsed.hostname.casefold() != expected_host.casefold()
    ):
        raise ValueError("probe redirect changed the configured hostname")
    try:
        port = parsed.port
    except ValueError as exc:
        raise ValueError("probe URL port is invalid") from exc
    expected_port = 80 if parsed.scheme == "http" else 443
    if port not in {None, expected_port}:
        raise ValueError("probe URL must use the default HTTP(S) port")
    try:
        addresses = {
            ipaddress.ip_address(item[4][0])
            for item in socket.getaddrinfo(
                parsed.hostname,
                expected_port,
                type=socket.SOCK_STREAM,
            )
        }
    except (OSError, ValueError) as exc:
        raise ValueError("probe URL host could not be resolved safely") from exc
    if not addresses or any(not address.is_global for address in addresses):
        raise ValueError("probe URL resolves to a non-public address")
    return parsed, tuple(sorted(str(address) for address in addresses))


def _now() -> str:
    return datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")
