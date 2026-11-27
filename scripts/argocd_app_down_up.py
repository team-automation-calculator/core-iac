#!/usr/bin/env python3
"""Take the app down through ArgoCD before a staging destroy, and bring it back up afterwards.

Step 1 of the destroy in docs/staging-destroy-and-recreate.md. Since ArgoCD migration Phase 9 the
add-ons destroy no longer deletes the app's Ingress: the app has no Helm release, and the
automation-calculator Application deliberately has no resources finalizer. Without this step the
load balancer controller is destroyed while the Ingress still exists, and the ALB is left behind.

    python3 -I scripts/argocd_app_down_up.py down staging            # dry run: show what it would do
    python3 -I scripts/argocd_app_down_up.py down staging --apply
    python3 -I scripts/argocd_app_down_up.py up staging --apply
    python3 -I scripts/argocd_app_down_up.py up staging --apply --from-file tmp/argocd-app/<file>.json

down: saves the Application to tmp/argocd-app/, adds resources-finalizer.argocd.argoproj.io to it
and deletes it, which makes ArgoCD delete the app's Deployment, Service, Ingress and the rest
first (the same as `argocd app delete --cascade`, without an ArgoCD login). Then waits until the
Application and the Ingress are gone and the ALB no longer exists. The namespace and the app
Secret are Terraform's and stay.

up: re-creates the Application exactly as Terraform's argocd-apps Helm release rendered it (read
with `helm get manifest`, or from a file saved by down), with Helm's ownership metadata so the
release still owns it. ArgoCD then syncs the app from main (staging has automated sync), and the
script waits for Synced/Healthy, the ALB, the Route 53 alias pointing at the new ALB, and a 200
from /health sent straight to the ALB (a resolver that looked the host up while the ALB was gone
can keep a negative answer for up to 15 minutes). Run with the Application already present, up
re-runs only the waits, and its dry run says whether the release manifest matches the live
Application, which is worth knowing before down.

Only staging is accepted: nothing in the repo takes production's app down. Writes need the
read-write kube context (the one named after the cluster ARN, not ac_app_<env>-ro); the default
is the context whose cluster is ac_app_<env> and whose name does not end in -ro. AWS reads use
the ac-ci-<env>-ro profile. Exits 0 on success, 1 on a failure or timeout.
"""

import argparse
import datetime as dt
import json
import logging
import pathlib
import socket
import ssl
import subprocess
import sys
import time

logger = logging.getLogger("argocd_app_down_up")

APP_NAME = "automation-calculator"
APP_NAMESPACE = "automation-calculator"
ARGOCD_NAMESPACE = "argocd"
APPS_RELEASE = "argocd-apps"
FINALIZER = "resources-finalizer.argocd.argoproj.io"
REGION = "us-west-1"
ENVIRONMENTS = {
    "staging": {
        "alb": "ac-app-staging",
        "host": "staging.automation-calculations.io",
        "profile": "ac-ci-staging-ro",
    },
}
BACKUP_DIR = pathlib.Path("tmp/argocd-app")
# Server-set fields that must not be sent back when re-creating an object from a saved copy.
SERVER_FIELDS = (
    "creationTimestamp",
    "deletionGracePeriodSeconds",
    "deletionTimestamp",
    "generation",
    "managedFields",
    "resourceVersion",
    "uid",
)


class Failure(Exception):
    """A step that did not succeed; main() logs it and exits 1."""


def run(
    cmd: list[str], stdin: str | None = None, check: bool = True
) -> subprocess.CompletedProcess:
    proc = subprocess.run(cmd, input=stdin, capture_output=True, text=True, check=False)
    if check and proc.returncode != 0:
        raise Failure(
            f"{' '.join(cmd[:4])} ... failed: {proc.stderr.strip() or proc.stdout.strip()}"
        )
    return proc


def pick_context(kubeconfig: dict, environment: str) -> str:
    """The read-write context for the environment's cluster: cluster name ends in
    /ac_app_<env> (EKS ARN) or equals ac_app_<env>, and the context name does not end in -ro.
    """
    cluster = f"ac_app_{environment}"
    matches = [
        ctx["name"]
        for ctx in kubeconfig.get("contexts") or []
        if not ctx["name"].endswith("-ro")
        and (
            ctx.get("context", {}).get("cluster", "").endswith(f"/{cluster}")
            or ctx.get("context", {}).get("cluster") == cluster
        )
    ]
    if len(matches) != 1:
        raise Failure(
            f"expected one read-write kube context for {cluster}, found {matches or 'none'}; "
            "run ./go infra-eng-sso or pass --context"
        )
    return matches[0]


def parse_objects(text: str) -> list[dict]:
    """kubectl -o json over a multi-document manifest prints one JSON object per document, one
    after the other; a List is flattened into its items."""
    decoder = json.JSONDecoder()
    objects, pos = [], 0
    while True:
        while pos < len(text) and text[pos].isspace():
            pos += 1
        if pos >= len(text):
            return objects
        obj, pos = decoder.raw_decode(text, pos)
        objects.extend(obj.get("items", []) if obj.get("kind") == "List" else [obj])


def find_application(objects: list[dict]) -> dict:
    for obj in objects:
        if (
            obj.get("kind") == "Application"
            and obj.get("metadata", {}).get("name") == APP_NAME
        ):
            return obj
    raise Failure(f"no Application {APP_NAME} in the {APPS_RELEASE} manifest")


def prepare_for_create(app: dict) -> dict:
    """A copy of the Application fit for `kubectl create`: no status, no server-set metadata,
    no finalizer (a re-created Application must not cascade on a later delete), and Helm's
    ownership label and annotations so the argocd-apps release keeps owning it."""
    app = json.loads(json.dumps(app))
    app.pop("status", None)
    meta = app.setdefault("metadata", {})
    for key in SERVER_FIELDS:
        meta.pop(key, None)
    meta.pop("finalizers", None)
    meta["namespace"] = ARGOCD_NAMESPACE
    meta.setdefault("labels", {})["app.kubernetes.io/managed-by"] = "Helm"
    annotations = meta.setdefault("annotations", {})
    annotations.pop("kubectl.kubernetes.io/last-applied-configuration", None)
    annotations["meta.helm.sh/release-name"] = APPS_RELEASE
    annotations["meta.helm.sh/release-namespace"] = ARGOCD_NAMESPACE
    return app


def spec_matches(source: dict, live: dict) -> bool:
    """True when the spec to re-create from equals the live one. The API server adds defaults
    to a stored Application, so only keys present in the source are compared."""

    def covered(want, have) -> bool:
        if isinstance(want, dict):
            return isinstance(have, dict) and all(
                covered(v, have.get(k)) for k, v in want.items()
            )
        if isinstance(want, list):
            return (
                isinstance(have, list)
                and len(want) == len(have)
                and all(covered(w, h) for w, h in zip(want, have, strict=True))
            )
        return want == have

    return covered(source.get("spec", {}), live.get("spec", {}))


def alb_info(names: list[dict], alb: str) -> dict | None:
    """State code and DNS name of the named ALB in describe-load-balancers output, None when
    absent."""
    for lb in names:
        if lb.get("LoadBalancerName") == alb:
            return {
                "state": lb.get("State", {}).get("Code", "unknown"),
                "dns": lb.get("DNSName", "").lower().rstrip("."),
            }
    return None


def alias_targets(record_sets: list[dict], host: str) -> set[str]:
    """Alias target DNS names of the host's A records, lower case, without the trailing dot
    and the dualstack. prefix Route 53 adds, so they compare equal to the ALB's DNSName.
    """
    targets = set()
    for rs in record_sets:
        if rs.get("Type") == "A" and rs.get("Name", "").rstrip(".") == host:
            dns = rs.get("AliasTarget", {}).get("DNSName", "").lower().rstrip(".")
            targets.add(dns.removeprefix("dualstack."))
    return targets - {""}


class Cluster:
    def __init__(self, context: str, environment: str):
        self.context = context
        self.env = ENVIRONMENTS[environment]

    def kubectl(self, *args: str, stdin: str | None = None, check: bool = True):
        return run(
            ["kubectl", "--context", self.context, *args], stdin=stdin, check=check
        )

    def application(self) -> dict | None:
        proc = self.kubectl(
            "-n",
            ARGOCD_NAMESPACE,
            "get",
            "applications.argoproj.io",
            APP_NAME,
            "-o",
            "json",
            check=False,
        )
        if proc.returncode != 0:
            if "NotFound" in proc.stderr:
                return None
            raise Failure(f"reading the Application failed: {proc.stderr.strip()}")
        return json.loads(proc.stdout)

    def ingress_count(self) -> int:
        proc = self.kubectl("-n", APP_NAMESPACE, "get", "ingress", "-o", "json")
        return len(json.loads(proc.stdout).get("items", []))

    def aws(self, *args: str) -> dict:
        proc = run(
            [
                "aws",
                *args,
                "--profile",
                self.env["profile"],
                "--region",
                REGION,
                "--output",
                "json",
            ]
        )
        return json.loads(proc.stdout)

    def alb(self) -> dict | None:
        lbs = self.aws("elbv2", "describe-load-balancers").get("LoadBalancers", [])
        return alb_info(lbs, self.env["alb"])

    def dns_targets(self) -> set[str]:
        """Where Route 53 points the host now (authoritative, no resolver cache involved)."""
        host = self.env["host"]
        zone = host.split(".", 1)[1]
        zones = self.aws("route53", "list-hosted-zones-by-name", "--dns-name", zone)
        zone_id = next(
            z["Id"]
            for z in zones.get("HostedZones", [])
            if z["Name"].rstrip(".") == zone and not z["Config"].get("PrivateZone")
        )
        records = self.aws(
            "route53",
            "list-resource-record-sets",
            "--hosted-zone-id",
            zone_id,
            "--start-record-name",
            host,
            "--max-items",
            "10",
        )
        return alias_targets(records.get("ResourceRecordSets", []), host)

    def rendered_application(self) -> dict:
        manifest = run(
            [
                "helm",
                "get",
                "manifest",
                APPS_RELEASE,
                "-n",
                ARGOCD_NAMESPACE,
                "--kube-context",
                self.context,
            ]
        ).stdout
        converted = self.kubectl(
            "create", "--dry-run=client", "-o", "json", "-f", "-", stdin=manifest
        )
        return find_application(parse_objects(converted.stdout))


def wait_for(what: str, check, timeout: float, interval: float = 10) -> None:
    deadline = time.monotonic() + timeout
    last = None
    while True:
        done, detail = check()
        if detail != last:
            logger.info("%s: %s", what, detail)
            last = detail
        if done:
            return
        if time.monotonic() > deadline:
            raise Failure(
                f"timed out after {timeout:.0f}s waiting for {what} ({detail})"
            )
        time.sleep(interval)


def health(host: str, connect_to: str) -> str:
    """GET https://<host>/health, connecting to connect_to (the ALB's own DNS name) with SNI,
    Host header and certificate check all for <host>. Going straight to the ALB keeps a
    negative answer for <host>, cached by this machine's resolver while the ALB was gone (up
    to the zone's 900 s negative TTL), from failing the check."""
    context = ssl.create_default_context()
    try:
        with (
            socket.create_connection((connect_to, 443), timeout=5) as raw,
            context.wrap_socket(raw, server_hostname=host) as tls,
        ):
            tls.sendall(
                f"GET /health HTTP/1.1\r\nHost: {host}\r\n"
                "User-Agent: argocd_app_down_up\r\nConnection: close\r\n\r\n".encode()
            )
            status_line = tls.recv(64).split(b"\r\n", 1)[0].decode("latin-1")
    except (OSError, ssl.SSLError) as exc:
        return f"error {exc}"
    parts = status_line.split()
    return parts[1] if len(parts) > 1 else f"error bad status line {status_line!r}"


def down(cluster: Cluster, apply: bool, timeout: float) -> None:
    app = cluster.application()
    if app is None:
        logger.info("Application %s does not exist; nothing to delete", APP_NAME)
    else:
        BACKUP_DIR.mkdir(parents=True, exist_ok=True)
        stamp = dt.datetime.now(dt.UTC).strftime("%Y%m%dT%H%M%SZ")
        backup = (
            BACKUP_DIR / f"{APP_NAME}-{cluster.context.rsplit('/', 1)[-1]}-{stamp}.json"
        )
        backup.write_text(json.dumps(app, indent=2) + "\n")
        logger.info(
            "saved the Application to %s (holds the certificate ARN; keep it out of git)",
            backup,
        )
        logger.info(
            "Application %s: sync=%s health=%s finalizers=%s",
            APP_NAME,
            app.get("status", {}).get("sync", {}).get("status"),
            app.get("status", {}).get("health", {}).get("status"),
            app["metadata"].get("finalizers", []),
        )
        if not apply:
            logger.info(
                "dry run: would add %s and delete the Application; pass --apply",
                FINALIZER,
            )
            return
        if FINALIZER not in app["metadata"].get("finalizers", []):
            patch = {
                "metadata": {
                    "finalizers": [*app["metadata"].get("finalizers", []), FINALIZER]
                }
            }
            cluster.kubectl(
                "-n",
                ARGOCD_NAMESPACE,
                "patch",
                "applications.argoproj.io",
                APP_NAME,
                "--type",
                "merge",
                "-p",
                json.dumps(patch),
            )
            logger.info("added %s", FINALIZER)
        cluster.kubectl(
            "-n",
            ARGOCD_NAMESPACE,
            "delete",
            "applications.argoproj.io",
            APP_NAME,
            "--wait=false",
        )
        logger.info("deleted the Application; ArgoCD now deletes the app's resources")
    if not apply:
        return

    def app_and_ingress_gone():
        exists = cluster.application() is not None
        ingresses = cluster.ingress_count()
        return (
            not exists and ingresses == 0,
            f"application={'present' if exists else 'gone'} ingresses={ingresses}",
        )

    wait_for("app objects", app_and_ingress_gone, timeout)

    def alb_gone():
        info = cluster.alb()
        return info is None, f"{cluster.env['alb']} {info['state'] if info else 'gone'}"

    wait_for("ALB", alb_gone, timeout)
    logger.info("down: done; the add-ons destroy can go ahead")


def up(cluster: Cluster, apply: bool, timeout: float, from_file: str | None) -> None:
    existing = cluster.application()
    if from_file:
        source = json.loads(pathlib.Path(from_file).read_text())
        origin = from_file
    else:
        source = cluster.rendered_application()
        origin = f"the {APPS_RELEASE} release manifest"
    if existing is not None:
        # A check worth having before `down`: would `up` rebuild the same Application?
        same = spec_matches(source, existing)
        logger.info(
            "Application %s already exists; not re-creating it. Its spec %s %s",
            APP_NAME,
            "matches" if same else "DIFFERS FROM",
            origin,
        )
    else:
        logger.info("re-creating the Application from %s", origin)
        app = prepare_for_create(source)
        if not apply:
            logger.info("dry run: would create Application %s; pass --apply", APP_NAME)
            return
        cluster.kubectl("create", "-f", "-", stdin=json.dumps(app))
        logger.info("created the Application")
    if not apply:
        return

    def synced_healthy():
        app = cluster.application() or {}
        sync = app.get("status", {}).get("sync", {}).get("status")
        state = app.get("status", {}).get("health", {}).get("status")
        return sync == "Synced" and state == "Healthy", f"sync={sync} health={state}"

    wait_for("Application", synced_healthy, timeout)

    def alb_active():
        info = cluster.alb()
        state = info["state"] if info else "absent"
        return state == "active", f"{cluster.env['alb']} {state}"

    wait_for("ALB", alb_active, timeout)
    alb_dns = cluster.alb()["dns"]

    def dns_points_at_alb():
        targets = cluster.dns_targets()
        return alb_dns in targets, f"Route 53 A alias -> {sorted(targets) or 'none'}"

    wait_for(f"DNS for {cluster.env['host']}", dns_points_at_alb, timeout)
    host = cluster.env["host"]
    wait_for(
        "/health through the ALB",
        lambda: ((s := health(host, alb_dns)) == "200", s),
        timeout,
    )
    logger.info(
        "up: done. Resolvers that asked for %s while the ALB was gone may cache that "
        "negative answer for up to 15 minutes",
        host,
    )


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("action", choices=["down", "up"])
    ap.add_argument("env", choices=sorted(ENVIRONMENTS))
    ap.add_argument(
        "--apply", action="store_true", help="make the change (default: dry run)"
    )
    ap.add_argument(
        "--context", help="read-write kube context (default: found from the kubeconfig)"
    )
    ap.add_argument(
        "--from-file", help="up: a Application JSON saved by down, used instead of helm"
    )
    ap.add_argument(
        "--timeout", type=float, default=900, help="seconds per wait (default 900)"
    )
    args = ap.parse_args()
    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(message)s", stream=sys.stderr
    )

    try:
        context = args.context or pick_context(
            json.loads(run(["kubectl", "config", "view", "-o", "json"]).stdout),
            args.env,
        )
        logger.info(
            "%s %s on kube context %s%s",
            args.action,
            args.env,
            context,
            "" if args.apply else " (dry run)",
        )
        cluster = Cluster(context, args.env)
        if args.action == "down":
            down(cluster, args.apply, args.timeout)
        else:
            up(cluster, args.apply, args.timeout, args.from_file)
    except Failure as exc:
        logger.error("error: %s", exc)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
