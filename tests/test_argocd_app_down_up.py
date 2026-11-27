"""Tests for the pure helpers in scripts/argocd_app_down_up.py."""

import json

import pytest
from argocd_app_down_up import (
    FINALIZER,
    Failure,
    alb_info,
    alias_targets,
    find_application,
    parse_objects,
    pick_context,
    prepare_for_create,
    spec_matches,
)

STAGING_ARN = "arn:aws:eks:us-west-1:000000000000:cluster/ac_app_staging"


def kubeconfig(*contexts):
    return {
        "contexts": [
            {"name": name, "context": {"cluster": cluster}}
            for name, cluster in contexts
        ]
    }


# pick_context


def test_pick_context_skips_read_only_and_other_clusters():
    config = kubeconfig(
        (STAGING_ARN, STAGING_ARN),
        ("ac_app_staging-ro", STAGING_ARN),
        ("prod", "arn:aws:eks:us-west-1:000000000000:cluster/ac_app_production"),
    )
    assert pick_context(config, "staging") == STAGING_ARN


def test_pick_context_none_found():
    with pytest.raises(Failure, match="found none"):
        pick_context(kubeconfig(("ac_app_staging-ro", STAGING_ARN)), "staging")


def test_pick_context_ambiguous():
    config = kubeconfig((STAGING_ARN, STAGING_ARN), ("alias", STAGING_ARN))
    with pytest.raises(Failure, match="expected one"):
        pick_context(config, "staging")


# parse_objects and find_application


def test_parse_objects_reads_concatenated_documents_and_lists():
    text = (
        json.dumps(
            {"kind": "AppProject", "metadata": {"name": "automation-calculator"}},
            indent=2,
        )
        + "\n"
        + json.dumps(
            {
                "kind": "List",
                "items": [{"kind": "Application", "metadata": {"name": "x"}}],
            }
        )
        + "\n\n"
    )
    assert [o["kind"] for o in parse_objects(text)] == ["AppProject", "Application"]


def test_find_application_by_kind_and_name():
    objects = [
        {"kind": "AppProject", "metadata": {"name": "automation-calculator"}},
        {
            "kind": "Application",
            "metadata": {"name": "automation-calculator"},
            "spec": {},
        },
    ]
    assert find_application(objects)["kind"] == "Application"


def test_find_application_missing():
    with pytest.raises(Failure):
        find_application(
            [{"kind": "AppProject", "metadata": {"name": "automation-calculator"}}]
        )


# prepare_for_create


def test_prepare_for_create_strips_server_fields_and_finalizer_and_adds_helm_ownership():
    saved = {
        "kind": "Application",
        "metadata": {
            "name": "automation-calculator",
            "namespace": "argocd",
            "uid": "u",
            "resourceVersion": "1",
            "generation": 3,
            "creationTimestamp": "t",
            "deletionTimestamp": "t",
            "managedFields": [],
            "finalizers": [FINALIZER],
            "annotations": {"kubectl.kubernetes.io/last-applied-configuration": "{}"},
        },
        "spec": {"project": "automation-calculator"},
        "status": {"sync": {"status": "Synced"}},
    }
    app = prepare_for_create(saved)
    meta = app["metadata"]
    assert "status" not in app
    assert not {
        "uid",
        "resourceVersion",
        "generation",
        "finalizers",
        "deletionTimestamp",
    } & set(meta)
    assert meta["labels"]["app.kubernetes.io/managed-by"] == "Helm"
    assert meta["annotations"] == {
        "meta.helm.sh/release-name": "argocd-apps",
        "meta.helm.sh/release-namespace": "argocd",
    }
    assert app["spec"] == saved["spec"]
    assert saved["metadata"]["finalizers"] == [FINALIZER]  # the input is not modified


def test_prepare_for_create_sets_namespace_on_rendered_manifest():
    assert (
        prepare_for_create({"kind": "Application", "metadata": {"name": "a"}})[
            "metadata"
        ]["namespace"]
        == "argocd"
    )


# alb_info and alias_targets


def test_alb_info():
    lbs = [
        {"LoadBalancerName": "ac-app-production", "State": {"Code": "active"}},
        {
            "LoadBalancerName": "ac-app-staging",
            "State": {"Code": "provisioning"},
            "DNSName": "ac-app-staging-1.us-west-1.elb.amazonaws.com",
        },
    ]
    assert alb_info(lbs, "ac-app-staging") == {
        "state": "provisioning",
        "dns": "ac-app-staging-1.us-west-1.elb.amazonaws.com",
    }
    assert alb_info(lbs[:1], "ac-app-staging") is None


def test_alias_targets_normalises_and_filters_by_name_and_type():
    host = "staging.example.io"
    records = [
        {
            "Name": "staging.example.io.",
            "Type": "A",
            "AliasTarget": {"DNSName": "dualstack.AC-App-Staging-1.elb.amazonaws.com."},
        },
        {
            "Name": "staging.example.io.",
            "Type": "AAAA",
            "AliasTarget": {"DNSName": "dualstack.other.elb.amazonaws.com."},
        },
        {"Name": "a-extdns.staging.example.io.", "Type": "TXT"},
        {
            "Name": "www.staging.example.io.",
            "Type": "A",
            "AliasTarget": {"DNSName": "dualstack.www.elb.amazonaws.com."},
        },
    ]
    assert alias_targets(records, host) == {"ac-app-staging-1.elb.amazonaws.com"}
    assert alias_targets([], host) == set()


# spec_matches


def test_spec_matches_ignores_server_defaults_but_not_changed_values():
    source = {"spec": {"project": "p", "source": {"helm": {"valueFiles": ["a", "b"]}}}}
    live = {
        "spec": {
            "project": "p",
            "source": {"helm": {"valueFiles": ["a", "b"], "passCredentials": False}},
        }
    }
    assert spec_matches(source, live)
    live["spec"]["source"]["helm"]["valueFiles"] = ["a"]
    assert not spec_matches(source, live)
