#!/usr/bin/env python3
"""Check the wiki pages for broken repo references, identifiers and stale dates.

Usage (from the repo root):
    python3 -I scripts/wiki_lint.py                 # every page under wiki/
    python3 -I scripts/wiki_lint.py wiki/foo.md     # only the pages given
    python3 -I scripts/wiki_lint.py --max-age-days 60

Errors (exit status 1):
  - text that looks like an identifier the public repo must not carry: an AWS
    account id, a Route 53 zone or change id, an email address, a Terraform Cloud
    run id, an IPv4 address, IAM Identity Center ids or the portal host;
  - a markdown link or a backticked repo path that does not exist;
  - a page with no `Verified: YYYY-MM-DD` line;
  - a page under wiki/ that wiki/index.md does not link to.

Warnings (exit status unchanged): a `Verified:` date older than --max-age-days.
Standard library only, so ./go lint can run it before any dependency exists.
"""

import argparse
import datetime
import logging
import re
import sys
from pathlib import Path

logger = logging.getLogger("wiki_lint")

REPO_ROOT = Path(__file__).resolve().parent.parent
WIKI_DIR = REPO_ROOT / "wiki"
INDEX = "index.md"
DEFAULT_MAX_AGE_DAYS = 120

# Patterns for identifiers that must stay out of a public repo.
IDENTIFIER_PATTERNS = {
    "AWS account id": re.compile(r"(?<![\d.-])\d{12}(?![\d.-])"),
    "Route 53 zone id": re.compile(r"\bZ[0-9A-Z]{12,}\b"),
    "Route 53 change id": re.compile(r"\bC0[0-9A-Z]{12,}\b"),
    "email address": re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]*[A-Za-z]"),
    "Terraform Cloud run id": re.compile(r"\brun-[A-Za-z0-9]{16}\b"),
    "IPv4 address": re.compile(r"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])"),
    "Identity Center instance id": re.compile(r"\bssoins-[0-9a-f]+"),
    "identity store id": re.compile(r"\bd-[0-9a-f]{10}\b"),
    "Identity Center portal host": re.compile(r"awsapps\.com"),
}

# Backticked text starting with one of these is read as a repo path.
REPO_PATH_PREFIXES = (
    ".circleci/",
    ".claude/",
    "argocd/",
    "docs/",
    "helm/",
    "iac/",
    "plans/",
    "scripts/",
    "terraform/",
    "tests/",
    "version_dates/",
    "wiki/",
)
REPO_ROOT_FILES = {"AGENTS.md", "CLAUDE.md", "go.py", "pyproject.toml"}

VERIFIED = re.compile(r"^Verified: (\d{4}-\d{2}-\d{2})\s*$", re.MULTILINE)
MARKDOWN_LINK = re.compile(r"\]\(([^)\s]+)\)")
BACKTICKED = re.compile(r"`([^`\s]+)`")
PLACEHOLDER = re.compile(r"[<>*{}$]")


def identifier_findings(text):
    """(line number, kind, match) for each identifier-like string in the text."""
    findings = []
    for number, line in enumerate(text.splitlines(), start=1):
        for kind, pattern in IDENTIFIER_PATTERNS.items():
            for match in pattern.finditer(line):
                findings.append((number, kind, match.group(0)))
    return findings


def repo_path_candidate(token):
    """The repo-relative path a backticked token names, or None if it names none."""
    if PLACEHOLDER.search(token):
        return None
    path = re.sub(r":\d+(-\d+)?$", "", token).rstrip("/.,")
    if path in REPO_ROOT_FILES or path.startswith(REPO_PATH_PREFIXES):
        return path
    return None


def missing_references(page, text):
    """Links and backticked repo paths in a page that do not exist in the tree."""
    missing = []
    for target in MARKDOWN_LINK.findall(text):
        if re.match(r"[a-z]+:", target) or target.startswith("#"):
            continue
        resolved = (page.parent / target.split("#", 1)[0]).resolve()
        if not resolved.exists():
            missing.append(target)
    for token in BACKTICKED.findall(text):
        path = repo_path_candidate(token)
        if path and not (REPO_ROOT / path).exists():
            missing.append(path)
    return missing


def verified_date(text):
    """The page's `Verified:` date, or None when it has none."""
    match = VERIFIED.search(text)
    return datetime.date.fromisoformat(match.group(1)) if match else None


def pages_missing_from_index(wiki_dir):
    """Pages in the wiki directory that its index does not link to."""
    index = wiki_dir / INDEX
    if not index.is_file():
        return [INDEX]
    linked = set(MARKDOWN_LINK.findall(index.read_text()))
    return sorted(
        page.name
        for page in wiki_dir.glob("*.md")
        if page.name != INDEX and page.name not in linked
    )


def lint_page(page, today, max_age_days):
    """Log each problem in one page; return the number of errors."""
    text = page.read_text()
    name = page.relative_to(REPO_ROOT) if page.is_relative_to(REPO_ROOT) else page
    errors = 0
    for number, kind, value in identifier_findings(text):
        logger.error("%s:%d: looks like an %s: %s", name, number, kind, value)
        errors += 1
    for target in missing_references(page, text):
        logger.error("%s: reference does not exist: %s", name, target)
        errors += 1
    date = verified_date(text)
    if date is None:
        logger.error("%s: no 'Verified: YYYY-MM-DD' line", name)
        errors += 1
    elif (today - date).days > max_age_days:
        logger.warning(
            "%s: verified %s, more than %d days ago; re-check its facts",
            name,
            date,
            max_age_days,
        )
    return errors


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Check the wiki pages for broken repo references, identifiers and stale dates."
    )
    parser.add_argument("pages", nargs="*", type=Path, help="default: wiki/*.md")
    parser.add_argument("--max-age-days", type=int, default=DEFAULT_MAX_AGE_DAYS)
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")

    pages = [p.resolve() for p in args.pages] or sorted(WIKI_DIR.glob("*.md"))
    today = datetime.datetime.now(datetime.UTC).date()
    errors = sum(lint_page(page, today, args.max_age_days) for page in pages)
    if not args.pages:
        for name in pages_missing_from_index(WIKI_DIR):
            logger.error("wiki/%s: not linked from wiki/%s", name, INDEX)
            errors += 1
    if errors:
        logger.error("%d problem(s) in %d page(s)", errors, len(pages))
        return 1
    logger.info("%d wiki page(s) ok", len(pages))
    return 0


if __name__ == "__main__":
    sys.exit(main())
