"""Shared fixtures: a fake urllib.request.urlopen so no test touches the network."""

from __future__ import annotations

import email.message
import io
import json
import urllib.error
import urllib.request

import pytest

import app_image_provenance as prov

ON_MAIN_SHA = "638a128d4a54b3c9c7aff71887eb632558a2ce01"  # 0.9.6-871
BRANCH_SHA = "7fb83392ae9e679615b6451e0c92680b4957ecd2"  # 0.9.6-872
CONFIG_DIGEST = "sha256:abc123"


class FakeResponse:
    def __init__(self, body: bytes, status: int = 200):
        self._body = body
        self.status = status

    def read(self) -> bytes:
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def http_error(url: str, code: int, headers: dict | None = None):
    msg = email.message.Message()
    for key, value in (headers or {}).items():
        msg[key] = value
    return urllib.error.HTTPError(url, code, "error", msg, io.BytesIO(b""))


class FakeHttp:
    """Route URLs (by prefix) to a JSON body, raw bytes, or an exception."""

    def __init__(self):
        self.routes: dict[str, object] = {}
        self.requests: list[urllib.request.Request | str] = []

    def add(self, url: str, response: object) -> None:
        self.routes[url] = response

    def urlopen(self, request, timeout=None):
        self.requests.append(request)
        url = (
            request.full_url if isinstance(request, urllib.request.Request) else request
        )
        for prefix in sorted(self.routes, key=len, reverse=True):
            if url.startswith(prefix):
                response = self.routes[prefix]
                if isinstance(response, BaseException):
                    raise response
                if isinstance(response, bytes):
                    return FakeResponse(response)
                return FakeResponse(json.dumps(response).encode("utf-8"))
        raise AssertionError(f"unexpected URL in test: {url}")

    def urls(self) -> list[str]:
        return [
            r.full_url if isinstance(r, urllib.request.Request) else r
            for r in self.requests
        ]


@pytest.fixture
def fake_http(monkeypatch) -> FakeHttp:
    fake = FakeHttp()
    monkeypatch.setattr(urllib.request, "urlopen", fake.urlopen)
    monkeypatch.delenv("GITHUB_TOKEN", raising=False)
    monkeypatch.delenv("GH_TOKEN", raising=False)
    return fake


def manifest_url(tag: str) -> str:
    return f"{prov.REGISTRY_BASE_URL}/manifests/{tag}"


def compare_url(sha: str) -> str:
    return f"{prov.GITHUB_API_URL}/repos/{prov.APP_GITHUB_REPO}/compare/main...{sha}"


def add_image(fake: FakeHttp, tag: str, labels: dict | None) -> None:
    """Register registry responses for an image with the given labels."""
    fake.add(prov.REGISTRY_AUTH_URL, {"token": "anon"})
    fake.add(manifest_url(tag), {"config": {"digest": f"{CONFIG_DIGEST}-{tag}"}})
    fake.add(
        f"{prov.REGISTRY_BASE_URL}/blobs/{CONFIG_DIGEST}-{tag}",
        {"config": {"Labels": labels}},
    )


def add_revision(fake: FakeHttp, tag: str, sha: str, status: str) -> None:
    add_image(fake, tag, {prov.REVISION_LABEL: sha})
    fake.add(compare_url(sha), {"status": status})
