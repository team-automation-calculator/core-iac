"""Tests for normalize, to_txt_name, owner_of and build_plan in
scripts/external_dns_txt_prefix_migration.py."""

import pytest
from external_dns_txt_prefix_migration import (
    TXT_PREFIX,
    TxtRecord,
    build_plan,
    normalize,
    owner_of,
    to_txt_name,
)

HOST = "staging.automation-calculations.io"
WWW = f"www.{HOST}"


def ownership(owner="default", resource="ingress/automation-calculator/app"):
    return (
        f'"heritage=external-dns,external-dns/owner={owner},'
        f'external-dns/resource={resource}"'
    )


def alias_a(name):
    return {
        "Name": f"{name}.",
        "Type": "A",
        "AliasTarget": {"DNSName": "alb.example.", "HostedZoneId": "Z1"},
    }


def txt(name, *values, ttl=300):
    return {
        "Name": f"{name}.",
        "Type": "TXT",
        "TTL": ttl,
        "ResourceRecords": [{"Value": v} for v in values],
    }


# normalize


@pytest.mark.parametrize(
    ("name", "expected"),
    [
        ("Staging.Automation-Calculations.IO.", HOST),
        (HOST, HOST),
        ("example.com..", "example.com"),
        ("", ""),
        (".", ""),
    ],
)
def test_normalize(name, expected):
    assert normalize(name) == expected


# to_txt_name


@pytest.mark.parametrize(
    ("dns_name", "token", "prefix", "expected"),
    [
        # No prefix: the token is joined to the first label (external-dns <= 0.21).
        (HOST, "cname", "", "cname-staging.automation-calculations.io"),
        ("automation-calculations.io", "a", "", "a-automation-calculations.io"),
        # The %{record_type} prefix this migration moves to.
        (HOST, "cname", TXT_PREFIX, "cname-extdns.staging.automation-calculations.io"),
        (HOST, "a", TXT_PREFIX, "a-extdns.staging.automation-calculations.io"),
        (WWW, "aaaa", TXT_PREFIX, "aaaa-extdns.www.staging.automation-calculations.io"),
        (
            "automation-calculations.io",
            "a",
            TXT_PREFIX,
            "a-extdns.automation-calculations.io",
        ),
        # A prefix without the template still gets the token on the first label.
        (HOST, "a", "pre-", "pre-a-staging.automation-calculations.io"),
        # Single-label names.
        ("localhost", "a", "", "a-localhost"),
        ("localhost", "a", TXT_PREFIX, "a-extdns.localhost"),
    ],
)
def test_to_txt_name(dns_name, token, prefix, expected):
    assert to_txt_name(dns_name, token, prefix) == expected


# owner_of


def test_owner_of_quoted_route53_value():
    assert owner_of(ownership()) == "default"


def test_owner_of_owner_last_stops_at_closing_quote():
    value = '"heritage=external-dns,external-dns/owner=other"'
    assert owner_of(value) == "other"


def test_owner_of_unquoted_value():
    assert owner_of("heritage=external-dns,external-dns/owner=abc,x=y") == "abc"


@pytest.mark.parametrize(
    "value",
    ['"heritage=external-dns"', '"v=spf1 -all"', "", '"external-dns/owner="'],
)
def test_owner_of_missing_owner(value):
    assert owner_of(value) is None


# build_plan


def test_build_plan_alias_a_host_with_no_prefix_records():
    records = [
        alias_a(HOST),
        txt(f"cname-{HOST}", ownership(), ttl=300),
        txt(HOST, ownership(), '"v=spf1 -all"', ttl=60),
    ]
    [plan] = build_plan(records, [HOST])

    assert plan.host == HOST
    assert plan.tokens == ["cname"]
    # Lookup order: token-prefixed name first, then the legacy host-name TXT.
    assert [r.name for r in plan.old] == [f"cname-{HOST}", HOST]
    assert plan.new == {f"cname-extdns.{HOST}": None}
    assert plan.source == TxtRecord(f"cname-{HOST}", 300, [ownership()])


def test_build_plan_reports_existing_new_records():
    new_name = f"cname-extdns.{HOST}"
    records = [alias_a(HOST), txt(new_name, ownership())]
    [plan] = build_plan(records, [HOST])
    assert plan.new == {new_name: TxtRecord(new_name, 300, [ownership()])}
    assert plan.old == []
    assert plan.source is None


def test_build_plan_tokens_for_plain_a_aaaa_and_cname():
    records = [
        {"Name": f"{HOST}.", "Type": "A", "ResourceRecords": []},
        {"Name": f"{HOST}.", "Type": "AAAA", "ResourceRecords": []},
        {"Name": f"{WWW}.", "Type": "CNAME", "ResourceRecords": []},
    ]
    host_plan, www_plan = build_plan(records, [HOST, WWW])
    assert host_plan.tokens == ["a", "aaaa"]
    assert set(host_plan.new) == {f"a-extdns.{HOST}", f"aaaa-extdns.{HOST}"}
    assert www_plan.tokens == ["cname"]
    assert set(www_plan.new) == {f"cname-extdns.{WWW}"}


def test_build_plan_matches_names_case_insensitively():
    records = [alias_a(HOST.upper()), txt(f"CNAME-{HOST.upper()}", ownership())]
    [plan] = build_plan(records, [HOST])
    assert plan.tokens == ["cname"]
    assert plan.source is not None
    assert plan.source.name == f"cname-{HOST}"


def test_build_plan_ignores_txt_without_ownership_value():
    records = [alias_a(HOST), txt(HOST, '"v=spf1 -all"')]
    [plan] = build_plan(records, [HOST])
    assert plan.old == []
    assert plan.source is None


def test_build_plan_source_requires_default_owner():
    records = [
        alias_a(HOST),
        txt(f"cname-{HOST}", ownership(owner="someone-else")),
        txt(HOST, ownership(), ttl=60),
    ]
    [plan] = build_plan(records, [HOST])
    assert [r.name for r in plan.old] == [f"cname-{HOST}", HOST]
    # The first old record has the wrong owner, so the legacy one is the source.
    assert plan.source.name == HOST
    assert plan.source.ttl == 60


def test_build_plan_source_checks_only_first_ownership_value():
    records = [
        alias_a(HOST),
        txt(f"cname-{HOST}", ownership(owner="other"), ownership()),
    ]
    [plan] = build_plan(records, [HOST])
    assert len(plan.old) == 1
    assert plan.source is None


def test_build_plan_exits_when_host_has_no_records():
    with pytest.raises(SystemExit) as excinfo:
        build_plan([txt(HOST, ownership())], [HOST])
    assert HOST in str(excinfo.value.code)


def test_build_plan_no_hosts():
    assert build_plan([alias_a(HOST)], []) == []
