"""Bounded public-web search and source reading for the governed researcher.

DuckDuckGo documents its non-JavaScript search at
https://duckduckgo.com/duckduckgo-help-pages/features/non-javascript .
This is the public HTML site, not a promised search API: challenges/rate limits
are surfaced as failures. No browser cookies, credentials, proxy or scripts run.
"""
from __future__ import annotations

import base64
import hashlib
import http.client
import ipaddress
import json
import os
import re
import socket
import ssl
import subprocess
import sys
import time
from datetime import datetime, timezone
from html.parser import HTMLParser
from pathlib import Path
from xml.etree import ElementTree
from typing import Any
from urllib.parse import parse_qs, quote, urlencode, urljoin, urlsplit, urlunsplit


class WebToolError(RuntimeError):
    """A source could not be safely retrieved; no source text was invented."""


_HOST = re.compile(r"^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")
_SEARCH_HOSTS = ("lite.duckduckgo.com", "html.duckduckgo.com", "duckduckgo.com")
SEARCH_HOST = "lite.duckduckgo.com"
SEARCH_ENDPOINT = "https://lite.duckduckgo.com/lite/"


def validate_url(url: str, allowed_domains: list[str]) -> tuple[str, str]:
    """Validate syntax and host authorization before DNS or any network request."""
    if not isinstance(url, str) or not url or len(url) > 8192:
        raise WebToolError("web URL is empty or too long")
    if "\\" in url or any(ord(char) < 33 or ord(char) == 127 for char in url):
        raise WebToolError("web URL contains whitespace, control characters or backslashes")
    try:
        parsed = urlsplit(url)
        host = (parsed.hostname or "").encode("idna").decode("ascii").lower()
        port = parsed.port
    except (ValueError, UnicodeError) as exc:
        raise WebToolError("web URL is malformed") from exc
    if parsed.scheme.lower() != "https" or port not in (None, 443):
        raise WebToolError("only public HTTPS on port 443 is permitted")
    if parsed.username is not None or parsed.password is not None:
        raise WebToolError("credentials in source URLs are not permitted")
    if not _HOST.fullmatch(host) or host.rsplit(".", 1)[-1].isdigit() or host.endswith((".local", ".localhost", ".internal", ".invalid", ".test", ".onion")):
        raise WebToolError("source host must be a public DNS name")
    if "*" not in allowed_domains and host not in [value.lower() for value in allowed_domains]:
        raise WebToolError("source host is not allowed by the research policy")
    path = quote(parsed.path or "/", safe="/%:@!$&'()*+,;=-._~")
    query = quote(parsed.query, safe="%=&?/:@!$'()*+,;~-._")
    return urlunsplit(("https", host, path, query, "")), host


def _public_address(address: str) -> bool:
    try:
        value = ipaddress.ip_address(address)
    except ValueError:
        return False
    if not value.is_global or value.is_multicast or value.is_unspecified or value.is_reserved or value.is_loopback:
        return False
    if isinstance(value, ipaddress.IPv6Address):
        if value.ipv4_mapped or value.sixtofour or value.teredo or "%" in address:
            return False
        if value in ipaddress.ip_network("64:ff9b::/96") or value in ipaddress.ip_network("64:ff9b:1::/48"):
            return False
    return True


def resolve_public(host: str) -> list[tuple]:
    try:
        addresses = socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM, proto=socket.IPPROTO_TCP)
    except OSError as exc:
        raise WebToolError("source DNS resolution failed") from exc
    if not addresses or any(not _public_address(item[4][0]) for item in addresses):
        raise WebToolError("source DNS contains a private, reserved or local address")
    return addresses


class _PinnedHTTPSConnection(http.client.HTTPSConnection):
    """TLS checks the original hostname while TCP uses the validated DNS result."""

    def __init__(self, host: str, address: tuple, timeout: float):
        super().__init__(host, port=443, timeout=timeout, context=ssl.create_default_context())
        self._address = address

    def connect(self) -> None:
        family, kind, proto, _, sockaddr = self._address
        connection = socket.socket(family, kind, proto)
        try:
            connection.settimeout(self.timeout)
            connection.connect(sockaddr)
            if not _public_address(connection.getpeername()[0]):
                raise WebToolError("connected source peer is not a public address")
            self.sock = self._context.wrap_socket(connection, server_hostname=self.host)
        except BaseException:
            connection.close()
            raise


def _fetch_direct(url: str, settings: dict[str, Any]) -> dict[str, Any]:
    """Runs in a killable child: its parent bounds DNS, TLS and body wall time."""
    deadline = time.monotonic() + settings["timeout_seconds"]
    current = url
    for hop in range(settings["max_redirects"] + 1):
        current, host = validate_url(current, settings["allowed_domains"])
        addresses = resolve_public(host)
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise WebToolError("source fetch deadline exceeded")
        # No second DNS resolution, retries, proxy, cookies, or credential headers.
        connection = _PinnedHTTPSConnection(host, addresses[0], remaining)
        try:
            parts = urlsplit(current)
            target = parts.path + ("?" + parts.query if parts.query else "")
            connection.request("GET", target, headers={
                "User-Agent": "HermesResearchSetup/0.12 (public source reader)",
                "Accept": "text/html,application/xhtml+xml,text/plain,application/xml,application/json;q=0.9",
                "Accept-Encoding": "identity",
                "Connection": "close",
            })
            response = connection.getresponse()
            if response.status in (301, 302, 303, 307, 308):
                location = response.getheader("Location")
                if not location or hop >= settings["max_redirects"]:
                    raise WebToolError("source redirect is missing or exceeds the configured limit")
                current = urljoin(current, location)
                continue
            if response.status != 200:
                raise WebToolError(f"source returned HTTP {response.status}; it was not read")
            if response.getheader("Content-Encoding", "identity").lower() != "identity":
                raise WebToolError("compressed source responses are not accepted")
            content_type = response.getheader("Content-Type", "").split(";", 1)[0].lower().strip()
            if content_type not in ("text/html", "application/xhtml+xml", "text/plain", "application/xml", "text/xml", "application/json", "application/atom+xml"):
                raise WebToolError("source format is unsupported; use an accessible HTML or plain-text original")
            length = response.getheader("Content-Length")
            if length and (not length.isdecimal() or int(length) > settings["max_response_bytes"]):
                raise WebToolError("source exceeds the configured response-size limit")
            body = response.read(settings["max_response_bytes"] + 1)
            if len(body) > settings["max_response_bytes"]:
                raise WebToolError("source exceeds the configured response-size limit")
            charset = response.headers.get_content_charset() or "utf-8"
            return {"url": current, "content_type": content_type, "charset": charset,
                    "body_base64": base64.b64encode(body).decode("ascii"),
                    "fetched_at": datetime.now(timezone.utc).isoformat()}
        finally:
            connection.close()
    raise WebToolError("source redirect limit exceeded")


def fetch_public(url: str, settings: dict[str, Any]) -> dict[str, Any]:
    """Use a subprocess so even a stuck DNS lookup cannot exceed the deadline."""
    validate_url(url, settings["allowed_domains"])
    environment = {key: value for key, value in os.environ.items() if key.upper() in ("SYSTEMROOT", "WINDIR", "TEMP", "TMP")}
    try:
        completed = subprocess.run(
            [sys.executable, "-I", "-B", str(Path(__file__).resolve()), "--fetch"],
            input=json.dumps({"url": url, "settings": settings}), capture_output=True,
            # Leave a small part of the reserved whole-call time for collecting
            # the killed worker and recording a bounded timeout result.
            text=True, encoding="utf-8", timeout=max(0.5, settings["timeout_seconds"] - 0.25),
            env=environment, check=False,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
    except subprocess.TimeoutExpired as exc:
        raise WebToolError("source fetch timed out; the network worker was stopped") from exc
    if len(completed.stdout) > (settings["max_response_bytes"] * 2 + 10000):
        raise WebToolError("source worker exceeded its output limit")
    try:
        result = json.loads(completed.stdout)
    except (ValueError, TypeError) as exc:
        raise WebToolError("source worker failed without usable evidence") from exc
    if completed.returncode != 0 or not result.get("ok"):
        raise WebToolError(str(result.get("error", "source worker failed")))
    return result["result"]


class _TextParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.skip = 0
        self.in_title = False
        self.title: list[str] = []
        self.parts: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag in ("script", "style", "noscript", "template", "svg"):
            self.skip += 1
        if tag == "title":
            self.in_title = True
        if tag in ("p", "div", "li", "br", "h1", "h2", "h3", "tr", "article"):
            self.parts.append("\n")

    def handle_endtag(self, tag: str) -> None:
        if tag in ("script", "style", "noscript", "template", "svg") and self.skip:
            self.skip -= 1
        if tag == "title":
            self.in_title = False

    def handle_data(self, data: str) -> None:
        if not self.skip:
            self.parts.append(data)
            if self.in_title:
                self.title.append(data)


class _SearchParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.results: list[dict[str, str]] = []
        self.current: dict[str, str] | None = None
        self.capture: str | None = None

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attributes = dict(attrs)
        classes = (attributes.get("class") or "").split()
        if tag == "a" and ("result__a" in classes or "result-link" in classes):
            href = attributes.get("href") or ""
            if href.startswith("//"):
                href = "https:" + href
            parsed = urlsplit(href)
            if parsed.hostname in _SEARCH_HOSTS and parsed.path == "/l/":
                href = parse_qs(parsed.query).get("uddg", [""])[0]
            self.current = {"title": "", "url": href, "snippet": ""}
            self.results.append(self.current)
            self.capture = "title"
        elif ("result__snippet" in classes or "result-snippet" in classes) and self.current is not None:
            self.capture = "snippet"

    def handle_endtag(self, tag: str) -> None:
        if tag in ("a", "td"):
            self.capture = None

    def handle_data(self, data: str) -> None:
        if self.capture and self.current is not None:
            self.current[self.capture] += data


def _decode_body(response: dict[str, Any]) -> tuple[bytes, str]:
    try:
        body = base64.b64decode(response["body_base64"], validate=True)
        return body, body.decode(response.get("charset", "utf-8"), errors="replace")
    except (ValueError, LookupError, KeyError) as exc:
        raise WebToolError("source response could not be decoded") from exc


class WebTools:
    def __init__(self, policy: Any):
        self.policy = policy

    def _run(self, request_id: str, task_id: str, role: str, tool: str, url: str,
             query: str | None = None, max_results: int | None = None, provider: str = "duckduckgo") -> dict[str, Any]:
        settings = self.policy.authorize_web(request_id, task_id, role, tool)
        if tool == "search_web":
            search_host = 'export.arxiv.org' if provider == 'arxiv' else SEARCH_HOST
            if "*" not in settings["allowed_domains"] and search_host not in settings["allowed_domains"]:
                raise WebToolError("search provider host is not permitted by policy")
            if max_results is None:
                max_results = settings["max_results"]
            if isinstance(max_results, bool) or not isinstance(max_results, int) or not 1 <= max_results <= settings["max_results"]:
                raise WebToolError("requested search result count exceeds the configured limit")
        validate_url(url, settings["allowed_domains"])
        reservation = self.policy.reserve_budget(
            request_id, role, input_text="", max_output_tokens=0,
            timeout_seconds=settings["timeout_seconds"],
        )
        started = time.monotonic()
        try:
            if provider == 'arxiv':
                # arXiv asks single-connection clients to leave three seconds
                # between calls; include the pause in the reserved wall budget.
                time.sleep(3)
                settings = {**settings, 'timeout_seconds': max(0.5, settings['timeout_seconds'] - 3)}
            response = fetch_public(url, settings)
            body, source = _decode_body(response)
            result: dict[str, Any] = {
                "ok": True, "tool": tool, "request_id": request_id, "task_id": task_id,
                "source_url": response["url"], "fetched_at": response["fetched_at"],
                "response_sha256": hashlib.sha256(body).hexdigest(),
                "untrusted_source": True,
            }
            if tool == "search_web":
                if "anomaly-modal" in source or "challenge-form" in source:
                    raise WebToolError("search provider requested a challenge; search evidence is unavailable")
                if provider == 'arxiv':
                    if '<!DOCTYPE' in source.upper() or '<!ENTITY' in source.upper():
                        raise WebToolError('search XML declarations are not allowed')
                    try:
                        feed = ElementTree.fromstring(source)
                    except ElementTree.ParseError:
                        raise WebToolError('arXiv search response is malformed') from None
                    ns = '{http://www.w3.org/2005/Atom}'
                    items = []
                    for entry in feed.findall(ns + 'entry'):
                        original = entry.findtext(ns + 'id', '')
                        parts = urlsplit(original)
                        if parts.hostname != 'arxiv.org' or not parts.path.startswith('/abs/'):
                            continue
                        items.append({'url': 'https://arxiv.org' + parts.path,
                            'title': ' '.join(entry.findtext(ns + 'title', '').split()),
                            'snippet': ' '.join(entry.findtext(ns + 'summary', '').split())})
                else:
                    parser = _SearchParser()
                    parser.feed(source)
                    items = parser.results
                results: list[dict[str, str]] = []
                seen: set[str] = set()
                for item in items:
                    try:
                        cleaned, _ = validate_url(item["url"], settings["allowed_domains"])
                    except WebToolError:
                        continue
                    if cleaned in seen:
                        continue
                    seen.add(cleaned)
                    results.append({"url": cleaned, "title": item["title"].strip()[:1000],
                                    "snippet": item["snippet"].strip()[:3000]})
                    if len(results) >= max_results:
                        break
                if not results:
                    raise WebToolError("search returned no usable HTTPS source results")
                result.update(query=query, results=results, provider=provider,
                    source_kind='search_metadata_not_original_read')
            else:
                title = ""
                if response["content_type"] in ("text/html", "application/xhtml+xml"):
                    parser = _TextParser()
                    parser.feed(source)
                    source = "".join(parser.parts)
                    title = " ".join("".join(parser.title).split())[:1000]
                source = "\n".join(" ".join(line.split()) for line in source.splitlines() if line.strip())
                if not source.strip():
                    raise WebToolError("source did not contain readable text")
                limited = source[:settings["max_text_chars"]]
                result.update(url=response["url"], title=title, text=limited,
                              content_type=response["content_type"], truncated=len(limited) != len(source),
                              text_sha256=hashlib.sha256(limited.encode("utf-8")).hexdigest())
        finally:
            # A timeout/crash still consumes one attempt and time. No model tokens
            # are claimed for network I/O; future model input includes this text.
            self.policy.consume_budget(reservation, actual_output_tokens=0,
                                       elapsed_seconds=time.monotonic() - started)
        result["evidence_id"] = self.policy.record_web_evidence(request_id, task_id, role, tool, result)
        return result

    def search(self, request_id: str, task_id: str, role: str, query: str,
               max_results: int | None = None) -> dict[str, Any]:
        if not isinstance(query, str) or not query.strip() or len(query) > 1000 or any(ord(c) < 32 for c in query):
            raise WebToolError("search query must contain 1 to 1000 printable characters")
        if re.search(r'(?i)(?:^|\s)site:arxiv\.org(?:\s|$)', query):
            # Explicit site selection uses the official public metadata API,
            # not a challenge bypass. Its own policy and budget apply normally.
            # API documentation: https://info.arxiv.org/help/api/user-manual.html
            terms = re.sub(r'(?i)(?:^|\s)site:arxiv\.org(?=\s|$)', ' ', query).strip()
            terms = re.findall(r'"([^"]+)"|(\S+)', terms)
            words = [a or b for a, b in terms if (a or b).upper() not in ('AND', 'OR', 'NOT')]
            if not words or len(words) > 12:
                raise WebToolError('arXiv search requires 1 to 12 words or quoted phrases')
            query_value = ' AND '.join('all:"' + re.sub(r'[^\w\s-]', ' ', word) + '"' for word in words)
            settings = self.policy.authorize_web(request_id, task_id, role, 'search_web')
            count = settings['max_results'] if max_results is None else max_results
            if type(count) is not int or not 1 <= count <= settings['max_results']:
                raise WebToolError('requested search result count exceeds the configured limit')
            url = 'https://export.arxiv.org/api/query?' + urlencode({'search_query': query_value, 'start': 0, 'max_results': count})
            return self._run(request_id, task_id, role, 'search_web', url, query=query.strip(), max_results=count, provider='arxiv')
        url = SEARCH_ENDPOINT + "?" + urlencode({"q": query.strip()})
        return self._run(request_id, task_id, role, "search_web", url, query=query.strip(), max_results=max_results)

    def read(self, request_id: str, task_id: str, role: str, url: str) -> dict[str, Any]:
        return self._run(request_id, task_id, role, "read_web", url)


def main() -> int:
    if sys.argv[1:] != ["--fetch"]:
        return 2
    try:
        payload = json.loads(sys.stdin.read(20000))
        result = _fetch_direct(payload["url"], payload["settings"])
        print(json.dumps({"ok": True, "result": result}, ensure_ascii=True))
        return 0
    except Exception as exc:
        message = str(exc) if isinstance(exc, WebToolError) else "source network request failed"
        print(json.dumps({"ok": False, "error": message}, ensure_ascii=True))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
