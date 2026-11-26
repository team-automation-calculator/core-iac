# Access and verification

Verified: 2026-11-26

What each role could read when it was last tried, and the pitfalls met while checking a rollout. The
profiles and how to sign in are in `docs/aws-sso-auth.md`; the snapshot and polling tools are in the
`### Scripts` list of `AGENTS.md`.

## What the roles can read

- **Staging and production share one AWS account and one public hosted zone.** Account-level reads
  (CloudWatch metrics, `aws rds describe-db-instances`, ACM, Route 53, `aws eks list-clusters`) of
  production work through the staging profiles (2026-11-05, 2026-11-07).
- **The `-ro` Kubernetes identity cannot read Secrets**, so `helm list` and `helm get manifest` fail
  under it (#413 documents the limitation in `env_snapshot.py`). It can read the ArgoCD Application
  and AppProject since #495. It cannot `exec` into a pod.
- **Denied to every CI role:** `pricing:GetProducts`, Savings Plans offering rates, Cost Explorer.
  Use the public price list files (`./go rds-price-list-extract`, `./go ec2-worker-node-pricing`).
- Neither CI role can read the SSM parameter for the recommended EKS AMI.
- Development has no EKS cluster and no RDS instance.

## Kube contexts

- Two contexts on one cluster share credentials unless `aws eks update-kubeconfig` is given
  `--user-alias`; it also switches the current context. Both are handled in `docs/aws-sso-auth.md`
  (#426). Pass `--context ac_app_<env>-ro` to the snapshot scripts rather than relying on the
  ARN-named context, which other sessions re-point.

## Checking a rollout

- **`www.` hosts redirect (301) to the apex**, so `/health` answers 200 only on the apex host.
- **A staging external-dns pod also warns about production records**, because the zone is shared;
  read its log per host, not per pod (#411, 2026-11-07).
- **A Route 53 diff can include another workspace's in-flight apply** on the shared zone; compare
  against the certificate's validation options before blaming the PR.
- **The app's rate limiter counts per pod**, and running the app repo's smoke test more often than
  about every 2 minutes gets 429s.
- **Re-check a plan made from a stale ref.** Run `git fetch` before checking out `origin/main` for a
  "fresh plan"; a stale ref once planned "1 to destroy" (2026-11-19).
- **Verify a claim about hand-made cloud objects before writing it down.** A second Google service
  account was written into #454 and #456 and never existed; there is one,
  `terraform-google-workspace` (`docs/google-cloud-terraform.md`).
