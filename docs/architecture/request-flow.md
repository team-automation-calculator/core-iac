# Request and response flows

The diagrams use the production hostname. Staging is the same with `staging.` in front of it.

## Page request

```mermaid
sequenceDiagram
    autonumber
    actor B as Browser
    participant R53 as Route 53
    participant ALB as ALB ac-app-<env>
    participant N as Node (NodePort)
    participant P as Rails pod :3000
    participant DB as RDS PostgreSQL :5432

    B->>R53: resolve automation-calculations.io
    R53-->>B: ALB addresses (A alias written by external-dns)
    B->>ALB: GET http://... :80
    ALB-->>B: 301 to https (ssl-redirect 443)
    B->>ALB: GET https://... :443
    Note over ALB: TLS ends here with the ACM cert,<br/>backend protocol is plain HTTP inside the VPC
    ALB->>N: HTTP to instance target group (NodePort)
    Note over N: externalTrafficPolicy Local:<br/>only nodes running a pod pass the health check
    N->>P: forward to container port 3000
    P->>DB: SQL over DATABASE_URL
    DB-->>P: rows
    P-->>N: HTTP response
    N-->>ALB: response
    ALB-->>B: HTTPS response
```

Key elements:

| Hop | Element | Defined in |
|---|---|---|
| DNS | A alias for the host, ownership TXT with a record-type prefix | external-dns (`cluster-addons-layer/main.tf`) |
| TLS | ACM cert for the apex and `www`, listeners on `:80` and `:443`, ssl-redirect | `main_rails_app/main.tf`, `main_rails_app/values.yml` |
| Routing | Ingress host rule `/*` to the Service, ALB `target-type: instance` | `helm/automation-calculator/templates/ingress.yaml` |
| Service | `NodePort` port 80 to targetPort 3000 | `templates/service.yaml` |
| DB | SG allows 5432 only from the EKS cluster security group | `main_rails_app/main.tf` |

## `www` redirect

```mermaid
sequenceDiagram
    actor B as Browser
    participant ALB as ALB ac-app-<env>
    B->>ALB: GET https://www.automation-calculations.io/anything
    Note over ALB: Ingress rule for www uses the<br/>redirect-www annotation action
    ALB-->>B: 301 Location https://automation-calculations.io/
    Note over B,ALB: The pod never sees this request
```

## OAuth sign-in (GitHub or Google)

```mermaid
sequenceDiagram
    autonumber
    actor B as Browser
    participant ALB as ALB
    participant P as Rails pod (Devise + OmniAuth)
    participant NAT as NAT gateway
    participant IdP as GitHub / Google
    participant DB as RDS

    B->>ALB: POST sign-in with provider
    ALB->>P: forward
    P-->>B: 302 to provider authorize URL (client id from env)
    B->>IdP: authorize and consent
    IdP-->>B: 302 to /users/auth/<provider>/callback?code=...
    B->>ALB: GET callback
    ALB->>P: forward to users/omniauth_callbacks
    P->>NAT: token exchange (client secret from env)
    NAT->>IdP: HTTPS
    IdP-->>P: access token and profile
    P->>DB: find or create user
    P-->>B: session cookie + redirect into the app
```

The OAuth client secrets reach the pod as env vars from the Kubernetes Secret. See [aws-resources.md](aws-resources.md#how-secrets-reach-the-pod-key-names-only).

## Health checks

Every check hits the same endpoint. `GET /health` runs `SELECT 1` against the database and returns JSON that includes `short_commit_hash`, which is how a rollout is detected from outside the cluster.

```mermaid
sequenceDiagram
    participant K as kubelet
    participant TG as ALB target group
    participant HC as Route 53 health check
    participant P as Rails pod /health
    participant DB as RDS

    Note over K,P: startupProbe every 5 s, up to 36 failures (about 3 min to boot)
    K->>P: startup / readiness / liveness GET /health (5 s timeout)
    P->>DB: SELECT 1
    DB-->>P: ok
    P-->>K: 200 + short_commit_hash
    Note over K: readiness gates Service endpoints,<br/>liveness failures (3x) restart the container
    TG->>P: GET /health via NodePort
    P-->>TG: 200, target healthy
    HC->>P: HTTPS apex (through ALB)
    P-->>HC: 200
```

## Control loops that keep the edge in sync

These run continuously, independent of user traffic.

```mermaid
sequenceDiagram
    participant API as EKS API server
    participant LBC as aws-load-balancer-controller
    participant XD as external-dns
    participant ELB as ELBv2 API
    participant R53 as Route 53
    participant CW as CloudWatch
    participant SNS as SNS ac-app-<env>-alarms

    LBC->>API: watch Ingress, Service, EndpointSlices
    LBC->>ELB: create or update ALB ac-app-<env>, listeners, target group, registered nodes
    XD->>API: watch Ingress hosts
    XD->>ELB: (reads ALB hostname from Ingress status)
    XD->>R53: UPSERT A alias + ownership TXT (never deletes)
    loop every 60 s
        CW->>CW: evaluate ALB 5xx, target 5xx, p99 > 3 s, UnHealthyHostCount > 0
    end
    CW-->>SNS: ALARM / OK transition
    SNS-->>SNS: email to the subscribed address
```
