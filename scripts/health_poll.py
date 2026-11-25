#!/usr/bin/env python3
"""Poll an environment's /health endpoint and log every change, to bound an outage during a rollout.

Used while a Terraform Cloud apply or an ArgoCD sync is in flight: start it before the merge, read
the summary afterwards. It answers "did /health ever stop answering 200, from when to when, and
when did the short_commit_hash flip".

    python3 -I scripts/health_poll.py production tmp/386/health.log
    python3 -I scripts/health_poll.py staging tmp/488/health.log --minutes 10 --interval 2
    python3 -I scripts/health_poll.py staging tmp/488/health.log --until-hash a8af890

Writes one line per change of the response (and one at the start) to the log and stdout:
    2026-11-25T16:45:44Z 200 a8af890 database=ok
and, at the end, a summary line:
    2026-11-25T17:00:44Z summary polls=180 ok=180 not_ok=0 longest_not_ok=0s hashes=a8af890

Only GET https://<host>/health is sent; nothing else is read or written. Exits 0 when every poll
answered 200, 1 otherwise, and 2 when --until-hash was given and never seen.
"""

import argparse
import datetime as dt
import json
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field

HOSTS = {
    "staging": "staging.automation-calculations.io",
    "production": "automation-calculations.io",
}
OK_STATUS = "200"


def describe(body: str) -> str:
    """The parts of a /health body worth logging: the commit hash and the database state."""
    try:
        payload = json.loads(body)
    except ValueError:
        return "unparseable"
    if not isinstance(payload, dict):
        return "unparseable"
    return f"{payload.get('short_commit_hash', '-')} database={payload.get('database', '-')}"


def probe(url: str, timeout: float) -> str:
    """One GET, reduced to "<status> <hash> database=<state>" or "error <reason>"."""
    request = urllib.request.Request(url, headers={"User-Agent": "health_poll"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return f"{response.status} {describe(response.read().decode('utf-8', 'replace'))}"
    except urllib.error.HTTPError as exc:
        return f"{exc.code} -"
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        return f"error {getattr(exc, 'reason', exc)}"


@dataclass
class Tally:
    """Counts over a run of probes, and the longest stretch that was not a 200."""

    polls: int = 0
    ok: int = 0
    longest_not_ok: float = 0.0
    hashes: list[str] = field(default_factory=list)
    _not_ok_since: float | None = None

    def add(self, result: str, now: float) -> None:
        parts = result.split()
        self.polls += 1
        if parts[0] == OK_STATUS:
            self.ok += 1
            self._close(now)
            if (
                len(parts) > 1
                and parts[1] not in ("-", "unparseable")
                and parts[1] not in self.hashes
            ):
                self.hashes.append(parts[1])
        elif self._not_ok_since is None:
            self._not_ok_since = now

    def _close(self, now: float) -> None:
        if self._not_ok_since is not None:
            self.longest_not_ok = max(self.longest_not_ok, now - self._not_ok_since)
            self._not_ok_since = None

    def summary(self, now: float) -> str:
        self._close(now)
        return (
            f"summary polls={self.polls} ok={self.ok} not_ok={self.polls - self.ok} "
            f"longest_not_ok={self.longest_not_ok:.0f}s hashes={','.join(self.hashes) or '-'}"
        )


def stamp() -> str:
    return dt.datetime.now(dt.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("env", choices=sorted(HOSTS))
    ap.add_argument("log")
    ap.add_argument("--minutes", type=float, default=15)
    ap.add_argument("--interval", type=float, default=5)
    ap.add_argument("--timeout", type=float, default=5, help="seconds per request")
    ap.add_argument(
        "--until-hash",
        help="stop as soon as /health answers 200 with this short_commit_hash",
    )
    args = ap.parse_args()

    url = f"https://{HOSTS[args.env]}/health"
    deadline = time.monotonic() + args.minutes * 60
    tally = Tally()
    prev = None
    seen_target = False
    with open(args.log, "a") as log:

        def emit(text: str) -> None:
            line = f"{stamp()} {text}"
            print(line, flush=True)
            log.write(line + "\n")
            log.flush()

        while time.monotonic() < deadline:
            cur = probe(url, args.timeout)
            tally.add(cur, time.monotonic())
            if cur != prev:
                emit(cur)
                prev = cur
            if args.until_hash and cur.split()[:2] == [OK_STATUS, args.until_hash]:
                seen_target = True
                break
            time.sleep(args.interval)
        emit(tally.summary(time.monotonic()))

    if args.until_hash and not seen_target:
        return 2
    return 0 if tally.ok == tally.polls else 1


if __name__ == "__main__":
    sys.exit(main())
