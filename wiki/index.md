# Wiki

Verified: 2026-11-26

What has been observed about this repo's infrastructure and tooling: how long a rollout takes and
what it costs, which plan lines are expected, how Terraform Cloud behaves, what each role can read.
Every fact carries the date and the pull request it was seen in.

Rules live in `AGENTS.md`, procedures and runbooks in `docs/`, proposals in `plans/`. A wiki page
links to those instead of restating them. How to keep the wiki current is in the "Wiki" section of
`AGENTS.md`; `./go wiki-lint` checks it.

- [Rollout timings](rollout-timings.md): measured outage and duration for each kind of change
- [Known plan artifacts](plan-artifacts.md): plan lines that are expected, and ones that are now findings
- [Terraform Cloud behaviour](terraform-cloud.md): run queueing, token expiry, commit statuses, reading plans
- [Access and verification](access-and-verification.md): what each role can read, and pitfalls when checking a rollout
- [CloudWatch alarms](cloudwatch-alarms.md): which alarms exist, which fire on what, how to tell one receives data
