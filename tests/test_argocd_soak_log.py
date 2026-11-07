"""Tests for the soak-gate logic in scripts/argocd_soak_log.py (ArgoCD Phase 7)."""

import datetime as dt

import pytest
from argocd_soak_log import Cycle, evaluate


def cycle(day, kind="bump", history_id=None, manual=False, notes=""):
    return Cycle(
        date=dt.date(2026, 11, day),
        kind=kind,
        tag="0.9.6-990",
        pr=400 + day,
        history_id=history_id if history_id is not None else day,
        time_to_sync="3m",
        manual_intervention=manual,
        notes=notes,
    )


def test_empty_log_fails_with_soak_clock_not_started():
    result = evaluate([], dt.date(2026, 11, 20))
    assert not result.passed
    assert result.clean_bump_cycles == 0
    assert result.soak_start is None


def test_three_clean_bumps_over_seven_days_pass():
    cycles = [cycle(1), cycle(4), cycle(8)]
    result = evaluate(cycles, dt.date(2026, 11, 8))
    assert result.passed
    assert result.clean_bump_cycles == 3
    assert result.soak_days == 7


def test_three_clean_bumps_inside_a_week_fail_on_soak_days():
    result = evaluate([cycle(1), cycle(2), cycle(3)], dt.date(2026, 11, 5))
    assert not result.passed
    assert result.soak_days == 4


def test_manual_intervention_restarts_both_counts():
    cycles = [cycle(1), cycle(2), cycle(3, manual=True), cycle(5), cycle(6)]
    result = evaluate(cycles, dt.date(2026, 11, 20))
    assert not result.passed
    assert result.clean_bump_cycles == 2
    assert result.soak_start == dt.date(2026, 11, 5)
    assert result.last_intervention == dt.date(2026, 11, 3)


def test_rollbacks_are_counted_but_not_as_bumps():
    cycles = [cycle(1), cycle(2, kind="rollback"), cycle(3), cycle(9)]
    result = evaluate(cycles, dt.date(2026, 11, 9))
    assert result.passed
    assert result.clean_bump_cycles == 3
    assert result.rollback_cycles == 1


def test_row_round_trip_keeps_escaped_pipe_in_notes():
    original = cycle(2, notes="TFC 0 changes | production confirmed")
    parsed = Cycle.from_row(original.to_row(), line_number=1)
    assert parsed == original


@pytest.mark.parametrize(
    "row",
    [
        "| 2026-11-02 | deploy | 0.9.6-990 | #402 | 2 | 3m | no | x |",
        "| 2026-11-02 | bump | 0.9.6-990 | #402 | 2 | 3m | maybe | x |",
        "| 2026-11-02 | bump | 0.9.6-990 | #402 | 2 | 3m | no |",
    ],
)
def test_malformed_rows_are_rejected(row):
    with pytest.raises(ValueError):
        Cycle.from_row(row, line_number=7)
