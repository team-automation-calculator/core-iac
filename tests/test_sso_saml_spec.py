"""Consistency checks for iac/specs/sso/google-workspace-saml.json.

The SAML link between Google Workspace and IAM Identity Center is made by hand
in two consoles and neither side has an API for it, so the spec cannot be
compared with the live settings here. What can be checked is that the recorded
values agree with each other and with the login script: a spec edited on one
side only is the same mistake as a console edited on one side only. The repo
is public, so the spec must also stay free of real instance identifiers.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest
from infra_eng_sso import validate_sso_start_url

REPO_ROOT = Path(__file__).resolve().parent.parent
SPEC_PATH = REPO_ROOT / "iac" / "specs" / "sso" / "google-workspace-saml.json"
LOGIN_SCRIPT = REPO_ROOT / "scripts" / "infra_eng_sso.py"

# ACS hosts per endpoint kind, from the IAM Identity Center user guide
# ("Assertion Consumer Service (ACS) endpoints in the primary and additional
# AWS Regions").
ACS_HOST_SUFFIX = {
    "dual-stack": ".sso.signin.aws",
    "ipv4": ".signin.aws",
    "alternative-ipv4": ".signin.aws.amazon.com",
}

# Shapes of the identifiers that must not be committed: Identity Center
# instance id, identity store id, the ACS tenant id and the Google IdP id.
REAL_IDENTIFIER_RES = (
    re.compile(r"ssoins-[0-9a-f]{16}"),
    re.compile(r"\bd-[0-9a-f]{10}\b"),
    re.compile(r"/saml/acs/[0-9a-f]{8,}"),
    re.compile(r"idpid=[A-Za-z0-9]+"),
)


def load_spec() -> dict:
    return json.loads(SPEC_PATH.read_text())


def host(url: str) -> str:
    return url.split("//", 1)[1].split("/", 1)[0]


def test_spec_holds_no_real_instance_identifiers():
    text = SPEC_PATH.read_text()

    for pattern in REAL_IDENTIFIER_RES:
        assert not pattern.search(text), f"real identifier matching {pattern.pattern}"


def test_google_acs_url_is_one_identity_center_publishes():
    spec = load_spec()
    google = spec["google_workspace_saml_app"]
    aws = spec["aws_identity_center"]["service_provider"]

    assert google["acs_endpoint_kind"] == "dual-stack"
    assert google["acs_url"] == aws["acs_url_dual_stack"]


def test_google_acs_host_matches_its_declared_endpoint_kind():
    spec = load_spec()
    google = spec["google_workspace_saml_app"]
    region = spec["aws_identity_center"]["region"]

    expected_host = region + ACS_HOST_SUFFIX[google["acs_endpoint_kind"]]
    assert host(google["acs_url"]) == expected_host


def test_google_entity_id_is_the_identity_center_issuer():
    spec = load_spec()
    aws = spec["aws_identity_center"]
    google = spec["google_workspace_saml_app"]

    assert google["entity_id"] == aws["service_provider"]["issuer_url"]
    assert google["entity_id"].endswith("/<identity-store-id>")


def test_identity_provider_urls_are_googles():
    idp = load_spec()["aws_identity_center"]["identity_provider"]

    assert host(idp["sign_in_url"]) == "accounts.google.com"
    assert host(idp["issuer_url"]) == "accounts.google.com"


def test_name_id_is_the_primary_email():
    google = load_spec()["google_workspace_saml_app"]

    # Identity Center matches the SAML NameID against the user's userName,
    # which is the Workspace primary email.
    assert google["name_id_format"] == "EMAIL"
    assert google["name_id"] == "Basic Information > Primary email"


def test_login_script_uses_the_endpoints_the_google_app_accepts():
    spec = load_spec()
    dual_stack = spec["google_workspace_saml_app"]["acs_endpoint_kind"] == "dual-stack"
    script = LOGIN_SCRIPT.read_text()

    # The Google app holds one ACS URL. While it is the dual-stack one, the CLI
    # login has to go through the dual-stack endpoints, and vice versa.
    assert ('"AWS_USE_DUALSTACK_ENDPOINT": "true"' in script) == dual_stack
    assert (
        spec["cli_login"]["requires_env"].get("AWS_USE_DUALSTACK_ENDPOINT") == "true"
    ) == dual_stack


# Made-up identifiers in the real shapes, to turn the spec's placeholder URLs
# into URLs the script can be asked about.
PLACEHOLDER_VALUES = {
    "<instance-id>": "ssoins-examplexample000",
    "<identity-store-id>": "d-example000",
}


def portal_url(spec: dict, kind: str) -> str:
    url = spec["aws_identity_center"]["access_portal_urls"][kind]
    for placeholder, value in PLACEHOLDER_VALUES.items():
        url = url.replace(placeholder, value)
    assert "<" not in url, f"unfilled placeholder in {url}"
    return url


def test_login_script_accepts_only_the_portal_url_the_google_app_accepts():
    spec = load_spec()
    portals = spec["aws_identity_center"]["access_portal_urls"]
    required = spec["cli_login"]["requires_start_url"]

    # Same pairing as the endpoint variable: a dual-stack ACS URL on the
    # Google app means the login starts from the dual-stack portal URL.
    assert spec["google_workspace_saml_app"]["acs_endpoint_kind"] == "dual-stack"
    assert required == "dual_stack"

    validate_sso_start_url(portal_url(spec, required))
    validate_sso_start_url(portal_url(spec, required) + "/")

    rejected = [kind for kind in portals if kind != required]
    assert rejected == ["ipv4"]
    for kind in rejected:
        with pytest.raises(SystemExit) as error:
            validate_sso_start_url(portal_url(spec, kind))
        assert "legacy IPv4 portal URL" in str(error.value)


@pytest.mark.parametrize(
    "url",
    [
        "https://example.awsapps.com/start",
        "https://example.awsapps.com/start/",
        "https://example.awsapps.com/start#/",
        "https://d-example000.awsapps.com/start",
    ],
)
def test_login_script_rejects_the_legacy_portal_url(url):
    with pytest.raises(SystemExit) as error:
        validate_sso_start_url(url)

    assert "legacy IPv4 portal URL" in str(error.value)
    assert "https://ssoins-<id>.portal.<region>.app.aws" in str(error.value)


def test_login_script_rejects_the_instance_url():
    with pytest.raises(SystemExit) as error:
        validate_sso_start_url(
            "https://identitycenter.amazonaws.com/ssoins-examplexample000"
        )

    assert "instance (issuer) URL" in str(error.value)
