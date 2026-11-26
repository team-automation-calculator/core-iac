# Sign-up bot protection: AWS WAF challenge on the sign-up and password-reset forms

Status: **proposal** (not scheduled). Nothing below is implemented. Written 2026-11-25 after a
look at production's users table through the read-only database role
(`docs/db-read-only-access.md`) and the first day of stored app logs (`docs/app-logs.md`).
Figures are aggregates only: the repo is public, so no addresses, IPs or rows appear here.

Prices are from memory of AWS's public WAF pricing and are marked **verify**: check
https://aws.amazon.com/waf/pricing/ before a decision.

## Summary and recommendation

- **The app is getting slow, distributed bot sign-ups.** Of 541 accounts in production, 536 signed in
  exactly once (the automatic sign-in at sign-up) and never came back. They create nothing: the only
  data they own is the empty scenario the app creates for every new user. 23 of them came back for a
  password reset, a median of about 5.7 days after signing up.
- **They hide well.** 532 distinct sign-in IPs for 541 accounts, Tor exits among them; plausible
  gmail and yahoo addresses (a few early ones on throwaway "form testing" domains); never two
  sign-ups within a minute; spread evenly over the day. Volume peaked at 60 to 70 a month from May
  to August 2025 and is now 5 to 9 a month.
- **Likely motive: a generic form-abuse bot, not a targeted attack.** Subscription bombing (signing
  a victim's address up everywhere to bury real alerts in their inbox), email-enumeration, or
  cataloguing forms that accept sign-ups and send mail. The one sign-up in the stored logs walked
  home, sign-in, a failed sign-in, sign-up, the new scenario, password reset, profile, a profile
  update and sign-out at one request per second.
- **Harm today is low.** Production sends no mail (no SMTP is configured), so neither the welcome
  path nor password resets reach anyone. The cost is polluted user counts and a form that would
  become an abuse vector the day mail is turned on.
- **Recommendation: an AWS WAF web ACL on the app's ALB, managed entirely in this repo**, that
  challenges browsers on the sign-up and password-reset pages and blocks posts to those forms
  without a valid WAF token. No app change. Roll out in count mode first. Expected cost about
  **$7 to $12 per month per environment (verify)**.
- **Do it before the app turns on outbound mail.** Until then it is optional.

## What protects the forms today

- Devise `:registerable` and `:recoverable` with no `:confirmable`: a sign-up is a live account at
  once.
- No CAPTCHA, honeypot or sign-up-specific throttle in the app.
- The ALB has no WAF. The ALB controller's IRSA policy (the upstream module's standard policy)
  already includes the `wafv2` and `waf-regional` permissions needed to associate one.

## Proposal

### 1. Terraform: the web ACL

In `terraform/modules/aws/main_rails_app` (it already owns the app's ACM certificate, whose ARN
reaches the chart the same way), behind a new variable that defaults to off, for example
`signup_waf_enabled`, plus `signup_waf_enforce` (count versus enforce):

- `aws_wafv2_web_acl`, scope `REGIONAL`, default action allow, CloudWatch metrics on every rule.
- **Rule: challenge the form pages.** `GET /users/sign_up` and `GET /users/password/new` (exact path
  match) get the **Challenge** action: a silent JavaScript proof of work that sets the
  `aws-waf-token` cookie. Use **CAPTCHA** instead if headless browsers pass the challenge.
- **Rule: require the token on the form posts.** `POST /users` and `POST /users/password` (exact
  path, so the OAuth routes under `/users/auth/*` are untouched) are blocked unless the request
  carries a valid token. AWS advises against challenging a POST directly: the interstitial loses
  the form body. **Verify** in staging which statement detects an absent or invalid token on a rule
  that does not itself challenge (the `awswaf:managed:token:*` labels, or a CAPTCHA/Challenge
  action with a long immunity time on the POST as the fallback).
- **Optional: rate-based rule** on the two POST paths per source IP (for example 10 per 5 minutes).
- **Optional: AWS managed rule groups** `AWSManagedRulesAnonymousIpList` (Tor, hosting providers,
  VPNs) and `AWSManagedRulesAmazonIpReputationList`, scoped to the same paths so ordinary
  visitors on a VPN can still use the calculator.
- Count mode: every rule's action is overridden to **Count** while `signup_waf_enforce = false`.
- Output the ACL ARN.

### 2. Chart and ArgoCD: attach it to the ALB

- `helm/automation-calculator/templates/ingress.yaml` renders
  `alb.ingress.kubernetes.io/wafv2-acl-arn` only when a new value `ingress.wafAclArn` is set, so a
  render without it is byte-identical to today.
- `terraform/modules/kubernetes/argocd` passes the ARN as a second Helm parameter next to
  `ingress.certificateArn`.
- The ALB controller associates the ACL with the existing ALB. `ingress.albName`, the Ingress name
  and namespace do not change, so the ALB and target group are not replaced (see "Values layering"
  in `AGENTS.md`).

### 3. Rollout

Two pull requests per step, staging then production (`docs/promotion.md`):

1. Module and chart change with the variable off everywhere (no-op plan).
2. Staging: `signup_waf_enabled = true`, count mode. Check the rule metrics and sampled requests
   for a few days, sign up and reset a password by hand in a real browser, and check that
   Google and GitHub sign-in and the `/health` checks are unaffected.
3. Staging: enforce. Repeat the manual checks; check a scripted `POST /users` without a token is
   blocked.
4. Production: the same two steps, after staging is verified.

The `deploy-image` smoke tests use visitor scenarios and `GET /users/sign_in`, neither of which the
rules touch.

## Expected cost per month (verify)

| Item | Unit price | Per environment |
|---|---|---|
| Web ACL | $5.00 per ACL | $5 |
| Rules (2 custom, plus 1 rate-based, plus 2 managed groups if used) | $1.00 per rule | $2 to $5 |
| Requests inspected | $0.60 per million | under $1 at current traffic |
| Challenge and CAPTCHA attempts | $0.40 per 1,000 | under $1 at current traffic |
| **Total** | | **about $7 to $12** |

Staging plus production: $15 to $25 per month. Development is unused and stays off.

## Alternatives considered

- **Cloudflare Turnstile.** Free, an inline widget, no tracking cookies. Terraform can create the
  widget and keys (Cloudflare provider) and put the secret in the app Secret, but the form and a
  server-side token check are app-repo code, and the app's Content Security Policy must allow
  `challenges.cloudflare.com`. Better user experience, but split across two repos.
- **Google reCAPTCHA v3 or hCaptcha.** The same shape as Turnstile; reCAPTCHA brings Google
  tracking, hCaptcha shows more puzzles.
- **Honeypot field.** Zero cost, app code only; stops naive form fillers but not a bot driving a
  real browser, which the one logged sign-up appears to be.
- **Devise `:confirmable`.** The right long-term control, but it needs outbound mail, which
  production does not have, and on its own it makes the form a mail cannon for subscription
  bombing. Pair it with this proposal, never instead of it.
- **Rack::Attack throttle in the app.** Complements the WAF; per-pod counters are doubled at two
  replicas unless the shared cache store is used (`plans/rate-limit-shared-cache-store.md`).

## Housekeeping, separate from the WAF

- The 536 one-time accounts could be deleted (with their scenarios) once the WAF is enforcing. That
  is an app-side data change with the master user, not something the read-only roles can do.
- Production keeps no ALB access logs, and the app logs carry no referrer or user agent, so traffic
  sources and time on page come only from Google Analytics. The WAF's sampled requests would add
  user agents for the protected paths.
