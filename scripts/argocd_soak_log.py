#!/usr/bin/env python3
"""Maintain the ArgoCD staging soak log and evaluate the soak gate.

ArgoCD migration Phase 7 (docs/argocd-phase-7-staging-soak.md) records every
bump and rollback cycle that ArgoCD synced on staging in
docs/argocd-staging-soak-log.md, a markdown table. This script appends rows to
that table and rewrites its "Gate" section with the result of the soak gate
from docs/argocd-migration-plan.md, which must pass before Phase 8
(production) starts:

  1. at least three bump cycles synced by ArgoCD with no manual intervention,
     counted since the most recent cycle that needed one;
  2. at least one week (7 days) of soak since the first of those clean cycles.

A cycle with manual intervention (a hand-run `argocd app sync`, a `kubectl`
edit, a manual Helm command, anything that was not "merge the PR and wait")
restarts both counts. Rollback cycles are recorded too and reported, but only
bump cycles count toward the three.

Subcommands:
  add     append one cycle and refresh the gate section
  status  evaluate the gate, refresh the gate section and print pass/fail
          (exit 0 on pass, 1 on fail)

Both take --file to operate on another copy (used for testing against a
scratch copy in tmp/). Standard library only.

Examples:
  scripts/argocd_soak_log.py add --date 2026-11-02 --tag 0.9.7-981 --pr 390 \\
      --history-id 3 --time-to-sync 4m --manual-intervention no \\
      --notes "watcher bump; TFC staging planned 0 changes"
  scripts/argocd_soak_log.py add --date 2026-11-03 --kind rollback --tag 0.9.6-970 \\
      --pr 391 --history-id 4 --time-to-sync 3m --manual-intervention no \\
      --notes "revert of #390 synced by ArgoCD"
  scripts/argocd_soak_log.py status
"""

from __future__ import annotations

import argparse
import datetime as dt
import re
import sys
from dataclasses import dataclass
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPTS_DIR.parent
DEFAULT_LOG = REPO_ROOT / "docs" / "argocd-staging-soak-log.md"

CYCLES_HEADING = "## Cycles"
GATE_HEADING = "## Gate"
GATE_MARKER = "<!-- Managed by scripts/argocd_soak_log.py; do not edit by hand. -->"
COLUMNS = (
    "Date",
    "Kind",
    "Tag",
    "PR",
    "ArgoCD history ID",
    "Time to sync",
    "Manual intervention",
    "Notes",
)
KINDS = ("bump", "rollback")
UNESCAPED_PIPE_RE = re.compile(r"(?<!\\)\|")
REQUIRED_BUMP_CYCLES = 3
REQUIRED_SOAK_DAYS = 7


@dataclass
class Cycle:
    date: dt.date
    kind: str
    tag: str
    pr: int
    history_id: int
    time_to_sync: str
    manual_intervention: bool
    notes: str

    @classmethod
    def from_row(cls, row: str, line_number: int) -> "Cycle":
        # Notes may contain an escaped pipe (\|); split on unescaped pipes only.
        cells = [c.strip() for c in UNESCAPED_PIPE_RE.split(row.strip().strip("|"))]
        if len(cells) != len(COLUMNS):
            raise ValueError(
                f"line {line_number}: expected {len(COLUMNS)} cells, got {len(cells)}"
            )
        date, kind, tag, pr, history_id, time_to_sync, manual, notes = cells
        if kind not in KINDS:
            raise ValueError(f"line {line_number}: kind must be one of {KINDS}")
        if manual not in ("yes", "no"):
            raise ValueError(f"line {line_number}: manual intervention must be yes/no")
        return cls(
            date=dt.date.fromisoformat(date),
            kind=kind,
            tag=tag,
            pr=int(pr.lstrip("#")),
            history_id=int(history_id),
            time_to_sync=time_to_sync,
            manual_intervention=manual == "yes",
            notes=notes.replace("\\|", "|"),
        )

    def to_row(self) -> str:
        cells = (
            self.date.isoformat(),
            self.kind,
            self.tag,
            f"#{self.pr}",
            str(self.history_id),
            self.time_to_sync,
            "yes" if self.manual_intervention else "no",
            self.notes.replace("|", "\\|"),
        )
        return "| " + " | ".join(cells) + " |"


@dataclass
class GateResult:
    passed: bool
    reasons: list[str]
    clean_bump_cycles: int
    soak_days: int
    soak_start: dt.date | None
    rollback_cycles: int
    last_intervention: dt.date | None


def table_header() -> list[str]:
    return [
        "| " + " | ".join(COLUMNS) + " |",
        "|" + "|".join("---" for _ in COLUMNS) + "|",
    ]


def find_heading(lines: list[str], heading: str) -> int:
    for index, line in enumerate(lines):
        if line.strip() == heading:
            return index
    raise ValueError(f"heading {heading!r} not found in the soak log")


def section_end(lines: list[str], start: int) -> int:
    """Index of the next '## ' heading after start, or len(lines)."""
    for index in range(start + 1, len(lines)):
        if lines[index].startswith("## "):
            return index
    return len(lines)


def parse_cycles(lines: list[str]) -> tuple[list[Cycle], int]:
    """Return the cycles and the index at which a new row is appended."""
    start = find_heading(lines, CYCLES_HEADING)
    end = section_end(lines, start)
    cycles: list[Cycle] = []
    header_seen = False
    insert_at = None
    for index in range(start + 1, end):
        line = lines[index].strip()
        if not line.startswith("|"):
            continue
        if not header_seen:
            header_seen = True  # column header
            continue
        if set(line.replace("|", "").strip()) <= {"-", " ", ":"}:
            insert_at = index + 1  # separator row
            continue
        cycles.append(Cycle.from_row(line, index + 1))
        insert_at = index + 1
    if insert_at is None:
        raise ValueError("cycles table header not found under " + CYCLES_HEADING)
    return cycles, insert_at


def evaluate(cycles: list[Cycle], today: dt.date) -> GateResult:
    ordered = sorted(cycles, key=lambda c: (c.date, c.history_id))
    interventions = [c.date for c in ordered if c.manual_intervention]
    last_intervention = max(interventions) if interventions else None
    clean = [
        c
        for c in ordered
        if not c.manual_intervention
        and (last_intervention is None or c.date > last_intervention)
    ]
    clean_bumps = [c for c in clean if c.kind == "bump"]
    rollbacks = [c for c in ordered if c.kind == "rollback"]
    soak_start = clean[0].date if clean else None
    soak_days = (today - soak_start).days if soak_start else 0

    reasons: list[str] = []
    if len(clean_bumps) >= REQUIRED_BUMP_CYCLES:
        reasons.append(
            f"PASS: {len(clean_bumps)} bump cycle(s) without manual intervention"
            f" (need {REQUIRED_BUMP_CYCLES})"
        )
    else:
        reasons.append(
            f"FAIL: {len(clean_bumps)} bump cycle(s) without manual intervention"
            f" (need {REQUIRED_BUMP_CYCLES})"
        )
    if soak_start is None:
        reasons.append(
            f"FAIL: no clean cycle yet, soak clock not started (need {REQUIRED_SOAK_DAYS} days)"
        )
    elif soak_days >= REQUIRED_SOAK_DAYS:
        reasons.append(
            f"PASS: {soak_days} day(s) since the first clean cycle on {soak_start}"
            f" (need {REQUIRED_SOAK_DAYS})"
        )
    else:
        reasons.append(
            f"FAIL: {soak_days} day(s) since the first clean cycle on {soak_start}"
            f" (need {REQUIRED_SOAK_DAYS})"
        )
    if last_intervention is not None:
        reasons.append(
            f"note: last manual intervention on {last_intervention}; cycles up to"
            " that date do not count"
        )
    if rollbacks:
        reasons.append(
            f"note: {len(rollbacks)} rollback cycle(s) recorded (the plan's revert test)"
        )
    else:
        reasons.append("note: no rollback cycle recorded yet (the plan's revert test)")
    passed = all(not r.startswith("FAIL") for r in reasons)
    return GateResult(
        passed=passed,
        reasons=reasons,
        clean_bump_cycles=len(clean_bumps),
        soak_days=soak_days,
        soak_start=soak_start,
        rollback_cycles=len(rollbacks),
        last_intervention=last_intervention,
    )


def render_gate(result: GateResult, today: dt.date) -> list[str]:
    verdict = "PASS" if result.passed else "FAIL"
    lines = [
        GATE_HEADING,
        "",
        GATE_MARKER,
        "",
        f"**{verdict}** as of {today.isoformat()}: Phase 8 may"
        + (" start." if result.passed else " not start yet."),
        "",
    ]
    lines.extend(f"- {reason}" for reason in result.reasons)
    lines.append("")
    return lines


def write_gate(lines: list[str], result: GateResult, today: dt.date) -> list[str]:
    start = find_heading(lines, GATE_HEADING)
    end = section_end(lines, start)
    return lines[:start] + render_gate(result, today) + lines[end:]


def read_log(path: Path) -> list[str]:
    return path.read_text(encoding="utf-8").splitlines()


def write_log(path: Path, lines: list[str]) -> None:
    path.write_text("\n".join(lines).rstrip("\n") + "\n", encoding="utf-8")


def cmd_add(args: argparse.Namespace) -> int:
    lines = read_log(args.file)
    cycles, insert_at = parse_cycles(lines)
    cycle = Cycle(
        date=args.date,
        kind=args.kind,
        tag=args.tag,
        pr=args.pr,
        history_id=args.history_id,
        time_to_sync=args.time_to_sync,
        manual_intervention=args.manual_intervention == "yes",
        notes=args.notes,
    )
    for existing in cycles:
        if existing.history_id == cycle.history_id:
            print(
                f"ArgoCD history id {cycle.history_id} is already recorded"
                f" (PR #{existing.pr}, {existing.date})",
                file=sys.stderr,
            )
            return 2
    lines.insert(insert_at, cycle.to_row())
    result = evaluate(cycles + [cycle], args.today)
    write_log(args.file, write_gate(lines, result, args.today))
    print(f"Recorded: {cycle.to_row()}")
    print(f"Gate: {'PASS' if result.passed else 'FAIL'} as of {args.today}")
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    lines = read_log(args.file)
    cycles, _ = parse_cycles(lines)
    result = evaluate(cycles, args.today)
    if not args.no_write:
        write_log(args.file, write_gate(lines, result, args.today))
    print(f"Soak log: {args.file}")
    print(f"Cycles recorded: {len(cycles)}")
    for cycle in sorted(cycles, key=lambda c: (c.date, c.history_id)):
        print(f"  {cycle.to_row()}")
    print()
    print(f"Gate: {'PASS' if result.passed else 'FAIL'} as of {args.today}")
    for reason in result.reasons:
        print(f"  {reason}")
    return 0 if result.passed else 1


def parse_date(value: str) -> dt.date:
    try:
        return dt.date.fromisoformat(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"{value!r} is not YYYY-MM-DD") from exc


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--file",
        type=Path,
        default=DEFAULT_LOG,
        help=f"soak log to maintain (default: {DEFAULT_LOG.relative_to(REPO_ROOT)})",
    )
    parser.add_argument(
        "--today",
        type=parse_date,
        default=dt.date.today(),
        help="evaluation date for the gate (default: today, YYYY-MM-DD)",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    add = subparsers.add_parser("add", help="record one cycle")
    add.add_argument("--date", type=parse_date, required=True, help="merge date")
    add.add_argument("--kind", choices=KINDS, default="bump")
    add.add_argument("--tag", required=True, help="image.tag the cycle deployed")
    add.add_argument("--pr", type=int, required=True, help="PR number that was merged")
    add.add_argument(
        "--history-id",
        type=int,
        required=True,
        help="ArgoCD history ID of the sync (argocd app history)",
    )
    add.add_argument(
        "--time-to-sync",
        required=True,
        help="merge to sync finished, e.g. 4m (free text, keep it short)",
    )
    add.add_argument("--manual-intervention", choices=("yes", "no"), required=True)
    add.add_argument("--notes", default="", help="what happened; '|' is escaped")
    add.set_defaults(func=cmd_add)

    status = subparsers.add_parser("status", help="evaluate the soak gate")
    status.add_argument(
        "--no-write",
        action="store_true",
        help="print the result without rewriting the Gate section",
    )
    status.set_defaults(func=cmd_status)

    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except (OSError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
