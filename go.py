#!/usr/bin/env python3
"""./go <command> [args...]: the single entry point for working in this repo.

Standard library only: `./go init` has to run before any dependency is installed.
`go` is a symlink to this file, so Black and pytest see it as Python.

Each command checks only the tools it drives, so the Python commands (lint, test,
compile, format, check-images) run in CI images that have no terraform or helm.
Bare `./go` checks every tool.
"""

import logging
import os
import shutil
import subprocess
import sys
from pathlib import Path

logger = logging.getLogger(__name__)

REPO_ROOT = Path(__file__).resolve().parent
# Tools ./go drives, and how to get each one when it is missing.
REQUIRED_TOOLS = {
    "poetry": "pipx install poetry",
    "git": "xcode-select --install (macOS) or your package manager",
    "terraform": "brew install terraform, or scripts/install_tf.sh",
    "helm": "brew install helm",
}
REPO_STANDARDS = Path.home() / "git" / "repo-standards"
REPO_STANDARDS_URL = "https://github.com/stevenuray/repo-standards"


def run(*command):
    """Run a command from the repo root; a failure ends ./go with its exit status."""
    completed = subprocess.run(command, cwd=REPO_ROOT, check=False)
    if completed.returncode:
        sys.exit(completed.returncode)


def preflight(*tools):
    """Name every missing tool among those given (default: all); True when none is."""
    missing = {
        tool: REQUIRED_TOOLS[tool]
        for tool in (tools or REQUIRED_TOOLS)
        if not shutil.which(tool)
    }
    for tool, fix in missing.items():
        logger.error("missing required tool: %s (install: %s)", tool, fix)
    return not missing


def require(*tools):
    """End ./go before a command starts when a tool it drives is missing."""
    if not preflight(*tools):
        sys.exit(1)


def init(*args):
    """Set up the development environment from a fresh checkout."""
    require("poetry")
    run("poetry", "install", "--with", "dev", *args)


def test(*args):
    """Run the tests; extra arguments go to pytest."""
    require("poetry")
    run("poetry", "run", "pytest", *args)


def tracked_files(pattern):
    """The repo's files matching a git pathspec that git tracks."""
    listed = subprocess.run(
        ["git", "ls-files", pattern],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=True,
    )
    return listed.stdout.split()


def compile_check(*args):
    """Byte-compile the Python files given (default: every tracked one)."""
    require("poetry", "git")
    sources = [a for a in args if a.endswith(".py")] if args else tracked_files("*.py")
    if sources:
        run("poetry", "run", "python", "-m", "py_compile", *sources)


def shell_syntax_check():
    """Parse every tracked shell script with `bash -n`, running none of them."""
    for script in tracked_files("*.sh"):
        run("bash", "-n", script)


def lint(*args):
    """Compile-check, check formatting (Black), lint (Ruff), bash -n the shell scripts."""
    compile_check(*args)
    run("poetry", "run", "black", "--check", *(args or ["."]))
    run("poetry", "run", "ruff", "check", *(args or ["."]))
    if not args:
        shell_syntax_check()


def format_code(*args):
    """Format the code with Black."""
    require("poetry")
    run("poetry", "run", "black", *(args or ["."]))


def validate(*args):
    """Run lint, then the tests: everything that has to pass before a push."""
    lint()
    test()


def terraform_fmt(*args):
    """Format the Terraform files under terraform/."""
    require("terraform")
    run("terraform", "fmt", "-recursive", *args, "terraform/")


def terraform_fmt_check(*args):
    """Check Terraform formatting under terraform/, changing nothing (the CI form)."""
    require("terraform")
    run("terraform", "fmt", "-check", "-recursive", *args, "terraform/")


def helm_lint(*args):
    """Lint the app Helm chart with --strict, as CI does."""
    require("helm")
    run("helm", "lint", "helm/automation-calculator/", "--strict", *args)


def check_images(*args):
    """Check that image.tag values added to the chart values files since origin/main exist on Docker Hub."""
    require("git")
    run(
        sys.executable,
        "-I",
        "scripts/check_app_docker_image_versions.py",
        "--base",
        "origin/main",
        *args,
    )


def audit(*args):
    """Audit this repo against the shared repo standards (needs the checkout)."""
    script = REPO_STANDARDS / "scripts" / "audit_repo.py"
    if not script.is_file():
        logger.error(
            "no repo-standards checkout at %s; clone it: git clone %s %s",
            REPO_STANDARDS,
            REPO_STANDARDS_URL,
            REPO_STANDARDS,
        )
        sys.exit(1)
    run(sys.executable, "-I", str(script), *(args or ["."]))


def usage():
    width = max(len(name) for name in COMMANDS)
    lines = ["usage: ./go <command> [args...]", ""]
    for name, function in COMMANDS.items():
        lines.append(f"  {name:<{width}}  {function.__doc__.splitlines()[0]}")
    return "\n".join(lines)


def help_command(*args):
    """List the commands."""
    print(usage())


COMMANDS = {
    "init": init,
    "test": test,
    "compile": compile_check,
    "lint": lint,
    "format": format_code,
    "validate": validate,
    "fmt": terraform_fmt,
    "fmt-check": terraform_fmt_check,
    "helm-lint": helm_lint,
    "check-images": check_images,
    "audit": audit,
    "help": help_command,
}


def main():
    logging.basicConfig(
        level=os.environ.get("GO_LOG_LEVEL", "INFO").upper(),
        format="%(levelname)s: %(message)s",
    )
    if len(sys.argv) < 2:
        tools_present = preflight()
        if tools_present:
            logger.info("pre-flight: found %s", ", ".join(REQUIRED_TOOLS))
        print(usage())
        sys.exit(0 if tools_present else 1)
    if sys.argv[1] not in COMMANDS:
        sys.exit(f"unknown command: {sys.argv[1]}\n\n{usage()}")
    COMMANDS[sys.argv[1]](*sys.argv[2:])


if __name__ == "__main__":
    main()
