"""Tests for is_done and main in scripts/wait_commit_status.py.

The status sequences are the real descriptions Terraform Cloud posted on 2026-11-25:
merge commit 251e95c (PR #496, production cluster_addons_layer), PR head a5487e4 (speculative
plan) and merge commit c6ac375 (plan with no changes).
"""

import wait_commit_status
from wait_commit_status import is_done, main

CONTEXT = (
    "Terraform Cloud/team-automation-calculator/ac_app_production_cluster_addons_layer"
)
URL = "https://app.terraform.io/app/team-automation-calculator/workspaces/x/runs/run-1"

PLAN_PENDING = ("pending", "Terraform plan pending")
PLAN_SUCCESS = ("success", "Terraform plan: 2 to add, 0 to change, 0 to destroy.")
APPLY_PENDING = ("pending", "Terraform apply pending")
APPLY_SUCCESS = ("success", "Terraform apply: 2 added, 0 changed, 0 destroyed.")
NO_CHANGES = ("success", "Terraform plan has no changes")
PLAN_FAILURE = ("failure", "Terraform plan errored")


def status(state_description, context=CONTEXT):
    state, description = state_description
    return {
        "context": context,
        "state": state,
        "description": description,
        "target_url": URL,
        "updated_at": "2026-11-25T18:38:34Z",
    }


def run(monkeypatch, polls, *args):
    """Run main with each poll returning the next list of statuses (the last repeats).

    Returns (exit code, number of polls made). The clock advances only by sleeping.
    """
    clock = [0.0]
    calls = [0]

    def fake_fetch(sha):
        polled = polls[min(calls[0], len(polls) - 1)]
        calls[0] += 1
        return [status(p) if isinstance(p, tuple) else p for p in polled]

    def fake_sleep(seconds):
        clock[0] += seconds

    monkeypatch.setattr(wait_commit_status, "fetch", fake_fetch)
    monkeypatch.setattr(wait_commit_status.time, "time", lambda: clock[0])
    monkeypatch.setattr(wait_commit_status.time, "sleep", fake_sleep)
    code = main(["deadbeef", "--interval", "30", "--timeout", "600", *args])
    return code, calls[0]


MERGE_COMMIT = [
    [PLAN_PENDING],
    [PLAN_SUCCESS],
    [APPLY_PENDING],
    [APPLY_PENDING],
    [APPLY_SUCCESS],
]

# is_done


def test_is_done_default_any_terminal_state():
    assert is_done(status(PLAN_SUCCESS), until_applied=False)
    assert is_done(status(PLAN_FAILURE), until_applied=False)
    assert not is_done(status(APPLY_PENDING), until_applied=False)


def test_is_done_until_applied():
    assert not is_done(status(PLAN_PENDING), until_applied=True)
    assert not is_done(status(PLAN_SUCCESS), until_applied=True)
    assert not is_done(status(APPLY_PENDING), until_applied=True)
    assert is_done(status(APPLY_SUCCESS), until_applied=True)
    assert is_done(status(NO_CHANGES), until_applied=True)
    assert is_done(status(PLAN_FAILURE), until_applied=True)
    assert is_done(status(("error", "Terraform apply errored")), until_applied=True)


def test_is_done_until_applied_missing_description():
    assert not is_done(
        {"context": CONTEXT, "state": "success", "description": None}, True
    )


# main


def test_merge_commit_until_applied_waits_for_apply(monkeypatch, capsys):
    code, polls = run(monkeypatch, MERGE_COMMIT, "--until-applied")
    assert code == 0
    assert polls == 5
    lines = capsys.readouterr().out.splitlines()
    assert [line.split(f" {URL} ", 1)[1] for line in lines] == [
        PLAN_PENDING[1],
        PLAN_SUCCESS[1],
        APPLY_PENDING[1],
        APPLY_SUCCESS[1],
    ]


def test_merge_commit_default_stops_at_plan_success(monkeypatch):
    code, polls = run(monkeypatch, MERGE_COMMIT)
    assert code == 0
    assert polls == 2


def test_missed_apply_pending_still_prints_apply(monkeypatch, capsys):
    """Staging's apply pending lasted one second; a poll can go plan success -> apply success."""
    code, polls = run(monkeypatch, [[PLAN_SUCCESS], [APPLY_SUCCESS]], "--until-applied")
    assert code == 0
    assert polls == 2
    out = capsys.readouterr().out
    assert PLAN_SUCCESS[1] in out
    assert APPLY_SUCCESS[1] in out


def test_speculative_plan_default(monkeypatch):
    code, polls = run(monkeypatch, [[PLAN_PENDING], [PLAN_SUCCESS]])
    assert code == 0
    assert polls == 2


def test_no_changes_until_applied(monkeypatch):
    code, polls = run(monkeypatch, [[PLAN_PENDING], [NO_CHANGES]], "--until-applied")
    assert code == 0
    assert polls == 2


def test_failure_default_exits_zero(monkeypatch):
    code, _ = run(monkeypatch, [[PLAN_PENDING], [PLAN_FAILURE]])
    assert code == 0


def test_failure_until_applied_exits_two(monkeypatch):
    code, polls = run(monkeypatch, [[PLAN_PENDING], [PLAN_FAILURE]], "--until-applied")
    assert code == 2
    assert polls == 2


def test_plan_success_held_times_out_naming_workspace(monkeypatch, capsys):
    """A confirm-required workspace stays at the plan success; one auto-applied beside it."""
    other = (
        "Terraform Cloud/team-automation-calculator/ac_app_staging_cluster_addons_layer"
    )
    code, _ = run(
        monkeypatch,
        [[status(PLAN_SUCCESS), status(APPLY_SUCCESS, other)]],
        "--until-applied",
    )
    assert code == 1
    out = capsys.readouterr().out
    assert "timeout waiting for statuses" in out
    assert f"still waiting: {CONTEXT} success {PLAN_SUCCESS[1]}" in out
    assert f"still waiting: {other}" not in out


def test_filter_narrows_to_one_workspace(monkeypatch):
    other = "Terraform Cloud/team-automation-calculator/ac_app_production_tf_workspaces"
    code, polls = run(
        monkeypatch,
        [[status(APPLY_SUCCESS), status(PLAN_SUCCESS, other)]],
        "--until-applied",
        "--filter",
        "cluster_addons_layer",
    )
    assert code == 0
    assert polls == 1


def test_no_statuses_yet_times_out(monkeypatch, capsys):
    code, _ = run(monkeypatch, [[]], "--until-applied")
    assert code == 1
    assert "no status context matching 'Terraform' yet" in capsys.readouterr().out
