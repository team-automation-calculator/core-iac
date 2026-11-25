"""Tests for parse_index, semver_key and latest_stable in
scripts/argo_helm_chart_versions.py."""

import pytest
from argo_helm_chart_versions import latest_stable, parse_index, semver_key

INDEX = """\
apiVersion: v1
entries:
  argo-cd:
  - annotations:
      artifacthub.io/changes: |
        - kind: changed
          description: Bump argo-cd
    apiVersion: v2
    appVersion: v3.2.0
    created: "2026-10-01T12:00:00.000000000Z"
    dependencies:
    - condition: redis-ha.enabled
      name: redis-ha
      version: 4.33.2
    description: A Helm chart for Argo CD
    name: argo-cd
    urls:
    - https://github.com/argoproj/argo-helm/releases/download/argo-cd-9.1.0/argo-cd-9.1.0.tgz
    version: 9.1.0
  - apiVersion: v2
    appVersion: v3.1.5
    created: '2026-09-01T12:00:00Z'
    name: argo-cd
    version: 9.0.3
  argocd-apps:
  - apiVersion: v2
    deprecated: true
    name: argocd-apps
    version: 2.0.3

  - apiVersion: v2
    name: argocd-apps
    version: 2.0.2
generated: "2026-10-02T00:00:00Z"
  not-a-chart:
  - version: 1.0.0
"""


def test_parse_index_groups_entries_by_chart():
    entries = parse_index(INDEX)
    assert list(entries) == ["argo-cd", "argocd-apps"]
    assert [e["version"] for e in entries["argo-cd"]] == ["9.1.0", "9.0.3"]
    assert [e["version"] for e in entries["argocd-apps"]] == ["2.0.3", "2.0.2"]


def test_parse_index_keeps_scalars_and_unquotes():
    first = parse_index(INDEX)["argo-cd"][0]
    assert first["appVersion"] == "v3.2.0"
    assert first["created"] == "2026-10-01T12:00:00.000000000Z"
    assert parse_index(INDEX)["argo-cd"][1]["created"] == "2026-09-01T12:00:00Z"


def test_parse_index_ignores_nested_values():
    first = parse_index(INDEX)["argo-cd"][0]
    # Nested maps and lists are recorded as an empty value, not their contents;
    # the dependency's "version: 4.33.2" must not overwrite the chart version.
    assert first["annotations"] == ""
    assert first["dependencies"] == ""
    assert first["urls"] == ""
    assert first["version"] == "9.1.0"
    assert "condition" not in first
    assert "kind" not in first


def test_parse_index_stops_at_end_of_entries_block():
    assert "not-a-chart" not in parse_index(INDEX)


def test_parse_index_without_entries_is_empty():
    assert parse_index("apiVersion: v1\ngenerated: x\n") == {}
    assert parse_index("") == {}


def test_parse_index_chart_with_no_items():
    assert parse_index("entries:\n  empty-chart:\n") == {"empty-chart": []}


@pytest.mark.parametrize(
    ("version", "expected"),
    [
        ("1.2.3", (1, 2, 3)),
        ("v1.2.3", (1, 2, 3)),
        ("10.20.30", (10, 20, 30)),
        ("1.2.3+build.5", (1, 2, 3)),
        ("1.2.3-rc.1", None),
        ("1.2.3-0", None),
        ("1.2.3-rc.1+build", None),
        ("1.2", None),
        ("1.2.3.4", None),
        ("", None),
        ("latest", None),
        (" 1.2.3", None),
    ],
)
def test_semver_key(version, expected):
    assert semver_key(version) == expected


def test_semver_key_orders_numerically():
    assert semver_key("1.10.0") > semver_key("1.9.9")


def test_latest_stable_picks_highest_numeric_version():
    items = [{"version": "1.9.0"}, {"version": "1.10.0"}, {"version": "1.2.0"}]
    assert latest_stable(items) == {"version": "1.10.0"}


def test_latest_stable_skips_prereleases_and_unparseable():
    items = [
        {"version": "2.0.0-rc.1"},
        {"version": "garbage"},
        {"name": "no-version"},
        {"version": "1.0.0"},
    ]
    assert latest_stable(items) == {"version": "1.0.0"}


@pytest.mark.parametrize("flag", ["true", "True", "TRUE"])
def test_latest_stable_skips_deprecated(flag):
    items = [{"version": "2.0.0", "deprecated": flag}, {"version": "1.0.0"}]
    assert latest_stable(items) == {"version": "1.0.0"}


def test_latest_stable_keeps_explicitly_not_deprecated():
    items = [{"version": "2.0.0", "deprecated": "false"}]
    assert latest_stable(items) == items[0]


def test_latest_stable_first_wins_on_tie():
    first = {"version": "1.0.0", "id": "first"}
    second = {"version": "v1.0.0", "id": "second"}
    assert latest_stable([first, second]) is first


def test_latest_stable_none_when_nothing_qualifies():
    assert latest_stable([]) is None
    assert latest_stable([{"version": "1.0.0-beta"}]) is None


def test_end_to_end_on_sample_index():
    entries = parse_index(INDEX)
    assert latest_stable(entries["argo-cd"])["version"] == "9.1.0"
    assert latest_stable(entries["argocd-apps"])["version"] == "2.0.2"
