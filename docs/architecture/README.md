# Architecture diagrams

Mermaid diagrams of the automation-calculations.io platform. They show the AWS resources this repo manages, how a request travels through them, and how app and infra changes are validated and deployed. GitHub renders the diagrams inline.

| Document | What it shows |
|---|---|
| [aws-resources.md](aws-resources.md) | AWS resources per environment and global, which Terraform layer owns each one, human and CI access, and how secrets reach the pod (by name only) |
| [request-flow.md](request-flow.md) | Sequence diagrams: page request, `www` redirect, OAuth sign-in, health checks, and the controllers that keep DNS, the ALB and alarms in sync |
| [deploy-and-validate.md](deploy-and-validate.md) | What runs on a draft PR in the app repo and in this repo, how an image becomes a deploy PR, and the staging → production gate after merge |

## Scope and conventions

- **No secret values.** Secrets appear only by key name (for example `DATABASE_URL`). The diagrams leave out account IDs, ARNs, email addresses, and OAuth client IDs.
- `<env>` stands for `staging` or `production`. Both run the same stack in `us-west-1`. `development` has env configs that CircleCI validates, but they are never applied, so development has no cluster or database.
- Names in `code` match the names in Terraform or Kubernetes, so a diagram node can be searched for in the repo.
- Source of truth: `terraform/modules/aws/*`, `terraform/env/*`, `helm/automation-calculator/`, `.circleci/config.yml`, and the `deploy-image` and `validate-infra-rollout` skills in `.claude/skills/`. When those change, update these diagrams in the same PR.
