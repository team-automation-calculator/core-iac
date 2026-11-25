"""Tests for summarize_applications and diff_applications in scripts/env_snapshot.py."""

from env_snapshot import diff_applications, summarize_applications


def application(
    sync="Synced",
    health="Healthy",
    revision="6378820abcdef0123",
    automated=None,
    images=("stevenuray/automation-calculator:0.9.6-1021",),
    resources=(),
    initiated_by=None,
):
    spec = {"syncPolicy": {"syncOptions": ["CreateNamespace=true"]}}
    if automated is not None:
        spec["syncPolicy"]["automated"] = automated
    status = {
        "sync": {"status": sync, "revision": revision},
        "health": {"status": health},
        "summary": {"images": list(images)},
        "resources": list(resources),
    }
    if initiated_by is not None:
        status["operationState"] = {
            "phase": "Succeeded",
            "finishedAt": "2026-11-25T16:22:50Z",
            "operation": {"initiatedBy": initiated_by},
        }
    return {
        "metadata": {"name": "automation-calculator"},
        "spec": spec,
        "status": status,
    }


# summarize_applications


def test_summarize_automated_staging_application():
    data = {
        "items": [
            application(
                automated={"prune": True, "selfHeal": True},
                initiated_by={"automated": True},
                resources=[
                    {
                        "kind": "Deployment",
                        "name": "automation-calculator",
                        "status": "Synced",
                    }
                ],
            )
        ]
    }
    [row] = summarize_applications(data)
    assert row == {
        "name": "automation-calculator",
        "sync": "Synced",
        "revision": "6378820abcdef0123",
        "health": "Healthy",
        "sync_policy": "automated (prune, selfHeal)",
        "images": ["stevenuray/automation-calculator:0.9.6-1021"],
        "out_of_sync": [],
        "last_operation": {
            "phase": "Succeeded",
            "initiated_by": "automated",
            "finished_at": "2026-11-25T16:22:50Z",
        },
    }


def test_summarize_manual_production_application_out_of_sync():
    data = {
        "items": [
            application(
                sync="OutOfSync",
                initiated_by={"username": "admin"},
                resources=[
                    {
                        "kind": "Deployment",
                        "name": "automation-calculator",
                        "status": "OutOfSync",
                    },
                    {
                        "kind": "Service",
                        "name": "automation-calculator",
                        "status": "Synced",
                    },
                ],
            )
        ]
    }
    [row] = summarize_applications(data)
    assert row["sync_policy"] == "manual"
    assert row["out_of_sync"] == ["Deployment/automation-calculator"]
    assert row["last_operation"]["initiated_by"] == "user admin"


def test_summarize_tolerates_a_new_application_with_no_status():
    [row] = summarize_applications({"items": [{"metadata": {"name": "x"}, "spec": {}}]})
    assert row["sync"] is None
    assert row["health"] is None
    assert row["sync_policy"] == "manual"
    assert row["last_operation"] == {
        "phase": None,
        "initiated_by": None,
        "finished_at": None,
    }


def test_summarize_empty_list():
    assert summarize_applications({"items": []}) == []


# diff_applications


def summary(**kwargs):
    return summarize_applications({"items": [application(**kwargs)]})


def test_diff_same_with_new_revision_is_not_flagged():
    lines = diff_applications(summary(revision="aaaa"), summary(revision="bbbb"))
    assert lines[0].startswith("same ")
    assert "revision aaaa -> bbbb" in lines[0]
    assert not any(l.startswith("ATTENTION") for l in lines)


def test_diff_image_change_is_changed():
    lines = diff_applications(
        summary(),
        summary(images=["stevenuray/automation-calculator:0.9.6-1030"]),
    )
    assert lines[0].startswith("CHANGED")
    assert any("0.9.6-1030" in l for l in lines)


def test_diff_flags_application_not_synced_and_healthy_after():
    lines = diff_applications(
        summary(),
        summary(
            sync="OutOfSync",
            health="Progressing",
            resources=[
                {
                    "kind": "Deployment",
                    "name": "automation-calculator",
                    "status": "OutOfSync",
                }
            ],
        ),
    )
    assert lines[0].startswith("CHANGED")
    assert "    out of sync: Deployment/automation-calculator" in lines
    assert lines[-1] == (
        "ATTENTION automation-calculator is OutOfSync/Progressing after, expected Synced/Healthy"
    )


def test_diff_sync_policy_change_is_reported():
    lines = diff_applications(summary(), summary(automated={"prune": True}))
    assert lines[0].startswith("CHANGED")
    assert "    sync policy manual -> automated (prune)" in lines


def test_diff_added_and_removed():
    assert diff_applications([], summary())[0].startswith(
        "ADDED    automation-calculator"
    )
    assert diff_applications(summary(), []) == ["REMOVED  automation-calculator"]


def test_diff_missing_side():
    assert diff_applications(None, summary()) == [
        "not captured on one side (see the failed checks below)"
    ]


def test_diff_nothing_on_either_side():
    assert diff_applications([], []) == ["no Applications on either side"]
