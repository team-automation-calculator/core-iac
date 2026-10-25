# external-dns TXT prefix migration

Runbook for moving external-dns's TXT ownership records to the prefix
`%{record_type}-extdns.`, one environment at a time (staging first, then
production).

## Why

external-dns (txt registry, chart 1.21.1 / v0.21.0) proves it owns a DNS record
with a TXT record next to it. Without `--txt-prefix`, the TXT name for host
`first.rest` and record type token `t` is `t-first.rest`. Alias A records use
the token `cname`; AAAA records use `aaaa`.

For the production apex `automation-calculations.io` that name is
`cname-automation-calculations.io`. That name is **outside** the hosted zone
`automation-calculations.io.`, so the AWS provider silently drops it. The
registry's migration logic then sees the new-format TXT as missing and
force-UPSERTs the apex A record on every sync (every minute). That loop
never converges.

With the prefix `%{record_type}-extdns.`, external-dns builds TXT names as
prefix + first label + `.` + rest, so they always stay inside the zone:

| Host | Old TXT names | New TXT names |
|---|---|---|
| `automation-calculations.io` | `automation-calculations.io` (legacy), `cname-automation-calculations.io` (never written) | `cname-extdns.automation-calculations.io`, `aaaa-extdns.automation-calculations.io` |
| `www.automation-calculations.io` | `www.…` (legacy), `cname-www.…`, `aaaa-www.…` | `cname-extdns.www.…`, `aaaa-extdns.www.…` |
| `staging.automation-calculations.io` | `staging.…` (legacy), `cname-staging.…`, `aaaa-staging.…` | `cname-extdns.staging.…`, `aaaa-extdns.staging.…` |
| `www.staging.automation-calculations.io` | `www.staging.…` (legacy), `cname-www.staging.…`, `aaaa-www.staging.…` | `cname-extdns.www.staging.…`, `aaaa-extdns.www.staging.…` |

## The danger: DNS freezes if you skip pre-creation

Once the prefix is set, external-dns only recognises TXT names that match the
new prefix. All the old names stop counting, so every existing record looks
**unowned**. The planner (`plan/plan.go`) silently filters out updates to
unowned records and logs nothing about it. external-dns then reports "All
records are already up to date" while managing nothing. DNS is frozen, and the
next ALB replacement becomes an outage.

So the new-format TXT records must exist **before** the prefix is applied in an
environment. Keep the old records until the new setup is verified: as long as
they exist, rolling back is just reverting the variable.

## Tooling

`scripts/external_dns_txt_prefix_migration.py` (standard library plus the aws
CLI):

```bash
# Read-only: show current ownership TXT records and what would change
scripts/external_dns_txt_prefix_migration.py plan -e staging            # profile ac-ci-staging-ro

# Writes are dry runs unless you pass --apply (profile ac-ci-<env>)
scripts/external_dns_txt_prefix_migration.py create-new -e staging
scripts/external_dns_txt_prefix_migration.py create-new -e staging --apply
scripts/external_dns_txt_prefix_migration.py delete-old -e staging --apply
```

How the script behaves:

- **Hosts.** It reads the hosts from `automation_calculator_app_host` in the
  environment's cluster-addons-layer `terraform.tfvars`, plus the `www.` alias.
- **Names.** It builds TXT names with a port of external-dns's
  `AffixNameMapper.ToTXTName`.
- **Values.** It copies the TXT value and TTL from the existing `owner=default`
  ownership record for the same host, rather than hardcoding them.
- **create-new.** Uses `CREATE`. It skips records that already exist with the
  same value and refuses to touch records that exist with a different value.
- **delete-old.** Refuses to run unless every new record exists with the
  expected value. It removes only the `owner=default` external-dns value. If a
  TXT RRset also holds other values (for example SPF or site verification at
  the apex), it UPSERTs the remaining values instead of deleting the RRset.
- **Undo.** Every write prints its change batch and the **inverse batch**. Save
  the inverse batch: it is your rollback. Apply it with
  `aws route53 change-resource-record-sets --hosted-zone-id Z0212130UA03VYHTN72T --change-batch file://undo.json --profile ac-ci-<env>`.
- **Profiles.** Route 53 writes need `ac-ci-<env>`. The InfraEng permission
  sets and the `-ro` roles cannot write.

## Steps

### 1. Staging: pre-create the new TXT records (BEFORE merging the PR)

```bash
eval "$(scripts/infra_eng_sso.py up --environment staging)"   # configures + logs in the ac-ci-staging profile
# plan defaults to the -ro profile; pass --profile to reuse the write
# profile `up` just set up (the script ignores AWS_PROFILE)
scripts/external_dns_txt_prefix_migration.py plan -e staging --profile ac-ci-staging
scripts/external_dns_txt_prefix_migration.py create-new -e staging            # review the batch
scripts/external_dns_txt_prefix_migration.py create-new -e staging --apply    # save the inverse batch
scripts/external_dns_txt_prefix_migration.py plan -e staging --profile ac-ci-staging   # all 4 "present, value matches"
```

The new records are harmless to the running instances, which have no prefix.
With no prefix they parse `cname-extdns.staging.…` as owning a nonexistent
`extdns.staging.…` endpoint and ignore it. Policy is upsert-only, so nothing
gets deleted.

*Rollback:* apply the inverse batch to delete the 4 new records. You can also
just leave them.

### 2. Merge the PR that sets `external_dns_txt_prefix` for staging

The staging cluster-addons-layer workspace auto-applies on merge. Its plan
should show exactly one change: `helm_release.external-dns` gaining
`txtPrefix = "%{record_type}-extdns."`.

Merging also queues the production and development workspace runs, because
the shared module changed. Those plans must show **no change** to
`helm_release.external-dns`: an empty `external_dns_txt_prefix` renders no
`set` block. If the production plan shows any external-dns diff, do not
confirm it. Discard the run and investigate. Never confirm a stale helm plan in
TFC.

*Rollback:* revert the PR, or set the variable back to `""`. The old TXT
records are still in place, so the unprefixed instance picks up ownership
where it left off.

### 3. Verify staging

```bash
kubectl -n kube-system get deploy external-dns -o jsonpath='{.spec.template.spec.containers[0].args}'
#   expect --txt-prefix=%{record_type}-extdns.
kubectl -n kube-system logs deploy/external-dns --since=10m
#   expect "All records are already up to date" every sync; no errors and no repeated "Desired change"
scripts/external_dns_txt_prefix_migration.py plan -e staging --profile ac-ci-staging
#   expect all new records "present, value matches"
```

A caution about what these checks prove: "All records are already up to date"
also appears when ownership was **lost**, because updates to unowned records
are dropped without a log line. The Debug-level line `Skipping endpoint …
because owner id does not match` (and the metric
`external_dns_registry_skipped_records_owner_mismatch_per_sync`) only fire for
*creates*, not updates. If you raise the log level (chart value `logLevel`),
that line must not appear for the staging hosts. Its absence alone does not
prove ownership either.

Two things together give the evidence:

1. The TXT records exist at exactly the names the mapper builds, with
   `owner=default`. The `plan` output shows this. The script computes the old
   names with the same function, and they match the records external-dns
   actually wrote (`cname-www.staging.…` and so on), which validates the port.
2. Active drift test, staging only. Make a no-traffic-impact drift on one
   record and watch external-dns correct it: UPSERT
   `www.staging.automation-calculations.io` A, using the same alias target but
   with `EvaluateTargetHealth: false`. An owning instance logs
   `Desired change: UPSERT www.staging.automation-calculations.io A` on its
   next sync, together with an UPSERT of the matching `cname-extdns.www.…` TXT
   record, then `2 record(s) were successfully updated`, and the record is
   back to `true`. The following syncs must return to "All records are already
   up to date". If nothing happens within two syncs, ownership is not being
   read: roll back (step 2).

   **Verified on staging 2026-10-25** with the prefix live (chart 1.21.1, app
   v0.21.0): drift applied at 16:31:37Z, the UPSERT logged at 16:32:11Z, the
   record was `true` again at 16:32:22Z, and the next sync was quiet. The
   drift takes effect within one sync, so there is no DNS impact: the alias
   target never changes, only the health-evaluation flag on it.

   ```bash
   # drift.json: same Name/Type/AliasTarget as the live record, EvaluateTargetHealth false
   aws route53 change-resource-record-sets --hosted-zone-id Z0212130UA03VYHTN72T \
     --change-batch file://tmp/drift.json --profile ac-ci-staging
   kubectl -n kube-system logs deploy/external-dns -f | grep -E 'Desired change|successfully updated'
   # keep an undo.json with EvaluateTargetHealth true in case external-dns does not correct it
   ```

*Rollback:* same as step 2.

### 4. Wait, then delete the old staging TXT records

Let it run for at least a day, ideally across a staging app deploy. Then:

```bash
scripts/external_dns_txt_prefix_migration.py delete-old -e staging            # review: 6 record sets
scripts/external_dns_txt_prefix_migration.py delete-old -e staging --apply    # save the inverse batch
```

*Rollback:* apply the saved inverse batch to recreate the old records **before**
reverting the prefix. Once the old records are gone, reverting the prefix
alone would freeze staging DNS.

### 5. Production: pre-create, then a follow-up PR

Repeat step 1 with `-e production` (and `--profile ac-ci-prod` on `plan`), which creates 4 records. This includes
`cname-extdns.automation-calculations.io`, the record the apex loop was
missing. Then open a follow-up PR that sets
`external_dns_txt_prefix = "%%{record_type}-extdns."` in
`terraform/env/production/aws/us-west-1/cluster-addons-layer/terraform.tfvars`.
Confirm the production TFC run manually, only after checking that the plan
shows nothing but the `txtPrefix` change.

Verify as in step 3. The per-minute
`Desired change: UPSERT automation-calculations.io A` lines should stop. Note
that this alone also happens if ownership is lost, so check the `plan` output
too. Do not run the active drift test against production.

*Rollback:* revert the follow-up PR. The old production records still exist.

### 6. Production: delete the old TXT records

After the wait period, run `delete-old -e production` (4 record sets: the apex
legacy record, `www.` legacy, `cname-www.`, `aaaa-www.`) and save the inverse
batch.

*Rollback:* same as step 4.

## HCL gotcha: `%%{`

`%{` starts a Terraform template directive, in `.tf` **and** `.tfvars`. Writing
`"%{record_type}-extdns."` fails to parse with "Invalid template control
keyword". Write `"%%{record_type}-extdns."`, which Terraform renders as the
literal `%{record_type}-extdns.` that external-dns expects. Do not escape it a
second time in the module: the variable value is passed through unchanged.

## Shared zone, shared owner id (known risk, out of scope)

Staging and production run separate external-dns instances against the **same**
hosted zone (`Z0212130UA03VYHTN72T`), and both use owner id `default`. Each
instance therefore treats the other environment's records as its own:

- Policy upsert-only means neither deletes the other's records.
- A misconfigured ingress host in one environment could still overwrite the
  other environment's record.

A per-environment `txtOwnerId` would fix this. external-dns supports migrating
to it with `--txt-owner-id` set to the new id (chart value `txtOwnerId`) and
`--migrate-from-txt-owner=default` (passed through `extraArgs`, because chart
1.21.1 has no dedicated value for it). That is a separate change with its own
verification and is not part of this migration.

The stray `cname-development.automation-calculations.io` TXT record, left over
from the unprovisioned development environment, is also out of scope.
