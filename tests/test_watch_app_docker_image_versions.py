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


# production_pin and read_promoted_production_version

SHA = "1fe9139e7af37dc970e38a7648ab2c3ebf827fdc"


def test_production_pin_reads_the_aligned_tfvars_line():
    text = (
        "app_logs_enabled                  = true\n"
        f'argocd_app_target_revision        = "{SHA}"\n'
        "argocd_application_automated_sync = true\n"
    )
    assert watch.production_pin(text) == SHA


def test_production_pin_none_when_unpinned():
    assert watch.production_pin("argocd_enabled = true\n") is None


def test_promoted_version_reads_values_production_at_the_pin(tmp_path, monkeypatch):
    tfvars = tmp_path / "terraform.tfvars"
    tfvars.write_text(f'argocd_app_target_revision = "{SHA}"\n')
    monkeypatch.setattr(watch, "PRODUCTION_TFVARS", tfvars)
    calls = []

    class Result:
        returncode = 0
        stdout = "image:\n  tag: 0.9.6-1098\n"

    def run(cmd, **kwargs):
        calls.append(cmd)
        return Result()

    monkeypatch.setattr(watch.subprocess, "run", run)
    assert watch.read_promoted_production_version() == (SHA, "0.9.6-1098")
    assert calls == [
        ["git", "show", f"{SHA}:helm/automation-calculator/values-production.yaml"]
    ]


def test_promoted_version_without_a_pin_reads_the_working_tree(tmp_path, monkeypatch):
    tfvars = tmp_path / "terraform.tfvars"
    tfvars.write_text("argocd_enabled = true\n")
    values = tmp_path / "values-production.yaml"
    values.write_text('image:\n  tag: "0.9.6-1058"\n')
    monkeypatch.setattr(watch, "PRODUCTION_TFVARS", tfvars)
    monkeypatch.setitem(watch.VALUES_FILES, "production", values)
    assert watch.read_promoted_production_version() == (None, "0.9.6-1058")
