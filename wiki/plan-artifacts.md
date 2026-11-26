# Known plan artifacts

Verified: 2026-11-26

Plan lines that a PR body's "expected plan" tends to leave out. Read a plan against this page before
calling an extra line a stop condition, and before calling it harmless.

## Expected

**Base layer: one more in-place change on the node group.** `terraform/modules/aws/base-cluster-layer`
uses `terraform-aws-modules/eks` 21.29.0, whose managed node group defaults
`use_latest_ami_release_version = true` and reads the recommended AMI at plan time. So any base-layer
plan shows `aws_eks_node_group.this[0]` changing `release_version` whenever AWS has published a newer
AL2023 AMI since the last apply (#408, 2026-11-04: `1.36.5-20261023` to `1.36.5-20261031`; earlier on
2026-07-08 and 2026-10-25). Applying it rolls the node (timings in [rollout-timings.md](rollout-timings.md)),
so say so in the PR for production. To check: compare the node group's `releaseVersion`
(`aws eks describe-nodegroup`) with the newest `amazon-eks-node-al2023-*` image
(`aws ec2 describe-images --owners amazon`); neither CI role can read the SSM parameter.

**Upstream releases of unpinned registry modules.** The cluster-addons layer pins
`terraform-aws-modules/iam` at `~> 6.8`, so a new upstream minor shows up in each environment's next
add-ons plan. On 2026-11-25 v6.11.3 added one EC2 action to the ALB controller's IRSA policy: staging
applied it with an unrelated run and #386's production plan carried it as an extra "1 to change".

**A branch behind `main` plans the reverse of what `main` applied since.** #386's production plan
showed an image rollback after a production bump landed on `main` mid-review (2026-11-25). Merge
`main` in, let the speculative plan re-run, and check `git log origin/<branch>..origin/main` right
before merging anything that deploys to production.

**Production's plan carries every unapplied shared-module change.** Production applies shared code
only through its own pull requests (`docs/promotion.md`), so its plan can include changes from
several merged staging PRs.

**Development `tf_cloud`: 3 to add, 2 to change.** Development is unused and has no cluster or RDS.
Its `ac_app_development_tf_workspaces` plan re-creates the GitHub OAuth client (deleted on the
Terraform Cloud side) and the two workspaces' token references, and adds the run trigger (#244) and
workspace settings (#243) that were never applied there. Note it as known if the shape is exactly
this; say so if it differs. Never confirm that run as part of another change.

## Findings if they come back

**ACM validation CNAMEs replaced ("2 to add, 2 to destroy") in an add-ons plan.** Until #404
(2026-11-04) any pending change in `module.cluster_addons` also replaced the two
`automation_calculator_app_cert_validation` records, because a module-level `depends_on` on
`main_rails_app` deferred its Route 53 zone lookup to apply time. The env configs now carry a comment
forbidding that `depends_on`; seeing the replacement again means it, or something like it, is back.

**`aws_sns_topic_subscription.alarms_email[0]` "1 to add" in production.** AWS deletes an
unconfirmed email subscription after 3 days, so until #420 (2026-11-07) a misspelled, never
confirmed address re-appeared in every production add-ons plan more than 3 days after the last
apply. The subscription is confirmed now; the line coming back means it has lapsed.

## Historical

**Helm provider 2.x to 3.x.** The first 3.x plan (#357, 2026-11-04) migrated each `helm_release`
state with empty `set` lists, so all four releases planned an in-place update re-adding identical
values; the apply was one no-op `helm upgrade` per release. Upstream
hashicorp/terraform-provider-helm issues 1647 and 1652.
