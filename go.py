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


# Every file in scripts/ is a ./go command named after it (argocd_preflight.sh is
# `./go argocd-preflight`); the arguments go to the script unchanged. The one
# exception is check_app_docker_image_versions.py, which is `./go check-images`.
# tests/test_go.py fails when a script has no entry here.
SCRIPTS = {
    "infra_eng_sso.py": "SSO login and kubectl setup: AWS profiles, aws sso login, kubeconfig.",
    "update_kubeconfigs.sh": "Refresh the kubeconfig for every environment.",
    "launch_psql_pod.sh": "Launch a psql pod to connect to RDS.",
    "bump_app_docker_image_version.sh": "Bump image.tag and shortCommitHash for staging (default) or production.",
    "bump_app_docker_image_version_branch.sh": "Bump the app image on a new branch and open that target's PR.",
    "promote_to_production.sh": "Write the staging-verified main commit to promoted_ref for a production PR.",
    "watch_app_docker_image_versions.py": "Watch Docker Hub for a new app image tag and open the staging bump PR.",
    "argocd_phase1_render_diff.sh": "Diff the chart render at a git ref against the working tree, per env.",
    "sort_tfvars.sh": "Sort the terraform.tfvars files alphabetically.",
    "install_tf.sh": "Install a specific Terraform version.",
    "delete_first_eks_cluster.sh": "Delete the first EKS cluster (dev utility, destructive).",
    "external_dns_txt_prefix_migration.py": "Plan, create or delete external-dns TXT ownership records (dry run unless --apply).",
    "argocd_preflight.sh": "Read-only ArgoCD preflight: pod headroom, ALB replicas, helm/argocd CLIs.",
    "argo_helm_chart_versions.py": "Latest stable argo-cd / argocd-apps chart versions from the argo-helm index.",
    "argocd_canary_check.sh": "Read-only ArgoCD Phase 3 canary check on the current kubectl context.",
    "argocd_staging_verify.sh": "Read-only check that a merged bump reached an env through ArgoCD.",
    "argocd_soak_log.py": "Add cycles to the ArgoCD staging soak log and evaluate the soak gate.",
    "watch_addon_rollout.sh": "Wait for a kube-system add-on Deployment to roll past a baseline generation.",
    "wait_commit_status.py": "Poll a commit's GitHub statuses (Terraform Cloud runs) until none is pending (--until-applied: until applied).",
    "env_snapshot.py": "Read-only before/after snapshot of an environment, and a diff of two.",
    "tfc_workspace_inventory.py": "Read-only Terraform Cloud workspace inventory.",
    "ec2_worker_node_utilization.py": "Read-only CloudWatch CPU and burst-credit summary for a node group.",
    "ec2_worker_node_pricing.py": "us-west-1 rates for candidate node types from downloaded price files.",
    "rds_utilization_summary.py": "Read-only CloudWatch summary for every RDS instance.",
    "rds_status_poll.py": "Read-only poll of an env's RDS instances, one line per change.",
    "health_poll.py": "Poll an env's /health during a rollout, one log line per change.",
    "rds_price_list_extract.py": "Offline filter over the public AWS Price List CSV for RDS.",
    "alb_alarm_window.py": "Read-only replay of the app's CloudWatch alarms over an ALB metrics window.",
    "app_logs.py": "Read the app pods' stored logs in CloudWatch Logs (read-only).",
    "db_read_only_psql.py": "psql on an env's app database as a read-only role (--as infra-eng or ci).",
    "pr_checklist.py": "List the PRs an image contains and tick their test-plan items through gh.",
    "graphify_update.py": "Refresh the knowledge graph's code layer (graphify-out/), no LLM; main or a seeded worktree.",
    "graphify_status.py": "How far the knowledge graph is behind HEAD (--brief: one line, only when stale).",
    "graphify_seed.py": "Give a worktree its own copy of main's knowledge graph, refreshed to the branch.",
}
# The command the git-sync agent runs after it fast-forwards main
# ([git-sync] post_sync in .repo-standards.toml, rule graphify); tests/test_go.py
# checks that it exists and matches that file.
POST_SYNC_COMMAND = "graphify-update"
# Scripts reached through a command of another name.
SCRIPTS_WITH_OWN_COMMAND = {"check_app_docker_image_versions.py": "check-images"}


def script_command_name(filename):
    """argocd_preflight.sh -> argocd-preflight."""
    return Path(filename).stem.replace("_", "-")


def script_command(filename, summary):
    """The ./go command that runs scripts/<filename> with the arguments given.

    The script runs in the caller's working directory, exactly as it does when
    run by its path, and ./go exits with its status.
    """
    script = REPO_ROOT / "scripts" / filename
    interpreter = [sys.executable, "-I"] if filename.endswith(".py") else []

    def command(*args):
        sys.exit(
            subprocess.run([*interpreter, str(script), *args], check=False).returncode
        )

    command.__doc__ = summary
    return command


def usage():
    width = max(len(name) for name in COMMANDS)
    lines = ["usage: ./go <command> [args...]", ""]
    for name, function in COMMANDS.items():
        if name == FIRST_SCRIPT_COMMAND:
            lines += ["", "scripts/ (arguments go to the script; try --help):", ""]
        lines.append(f"  {name:<{width}}  {function.__doc__.splitlines()[0]}")
    return "\n".join(lines)


def help_command(*args):
    """List the commands."""
    print(usage())


SCRIPT_COMMANDS = {
    script_command_name(filename): script_command(filename, summary)
    for filename, summary in SCRIPTS.items()
}
FIRST_SCRIPT_COMMAND = next(iter(SCRIPT_COMMANDS))

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
    **SCRIPT_COMMANDS,
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
    try:
        COMMANDS[sys.argv[1]](*sys.argv[2:])
    except KeyboardInterrupt:
        sys.exit(130)


if __name__ == "__main__":
    main()
