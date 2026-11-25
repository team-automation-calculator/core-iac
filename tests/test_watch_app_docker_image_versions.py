"""Tests for the multi-arch handling in scripts/watch_app_docker_image_versions.py."""

import importlib.util
from pathlib import Path

import pytest

SCRIPT = (
    Path(__file__).resolve().parent.parent
    / "scripts"
    / "watch_app_docker_image_versions.py"
)
spec = importlib.util.spec_from_file_location("watch_app_docker_image_versions", SCRIPT)
watch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watch)


def entry(os_name, arch, digest):
    return {"digest": digest, "platform": {"os": os_name, "architecture": arch}}


def test_select_platform_digest_prefers_arm64():
    index = {
        "manifests": [
            entry("linux", "amd64", "sha256:amd"),
            entry("linux", "arm64", "sha256:arm"),
            entry("unknown", "unknown", "sha256:attestation"),
        ]
    }
    assert watch.select_platform_digest(index) == "sha256:arm"


def test_select_platform_digest_falls_back_to_amd64():
    index = {
        "manifests": [
            entry("unknown", "unknown", "sha256:attestation"),
            entry("linux", "amd64", "sha256:amd"),
        ]
    }
    assert watch.select_platform_digest(index) == "sha256:amd"


def test_select_platform_digest_rejects_an_index_without_a_linux_image():
    index = {"manifests": [entry("unknown", "unknown", "sha256:attestation")]}
    with pytest.raises(ValueError):
        watch.select_platform_digest(index)


def test_fetch_short_commit_hash_follows_an_image_index(monkeypatch):
    manifests = {
        "0.9.6-998": {"manifests": [entry("linux", "arm64", "sha256:arm")]},
        "sha256:arm": {"config": {"digest": "sha256:config"}},
    }
    monkeypatch.setattr(watch, "fetch_manifest", lambda ref, headers: manifests[ref])

    class Response:
        def __init__(self, body):
            self.body = body

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

        def read(self):
            return self.body

    def urlopen(request, timeout):
        url = request if isinstance(request, str) else request.full_url
        if "auth.docker.io" in url:
            return Response(b'{"token": "t"}')
        assert url.endswith("/blobs/sha256:config")
        label = (
            b'{"config": {"Labels": {"org.opencontainers.image.revision": "abc1234"}}}'
        )
        return Response(label)

    monkeypatch.setattr(watch.urllib.request, "urlopen", urlopen)
    assert watch.fetch_short_commit_hash("0.9.6-998") == "abc1234"
