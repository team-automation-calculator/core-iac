# AWS resources and how they connect

## Per-environment stack (`us-west-1`, staging and production)

Staging and production are identical apart from the hostname: `staging.automation-calculations.io` and `automation-calculations.io`.

```mermaid
flowchart TB
    user(["Browser"])
    dockerhub[("Docker Hub<br/>automationcalculationsci/automation-calculator")]
    oauth(["GitHub / Google OAuth"])
    r53[("Route 53 public zone<br/>automation-calculations.io")]
    acm["ACM certificate<br/>apex + www, DNS-validated"]

    subgraph vpc["VPC (one per environment)"]
        igw["Internet gateway"]

        subgraph pub["Public subnets public_1 / public_2 (2 AZs)"]
            alb["ALB ac-app-&lt;env&gt;<br/>internet-facing, :80 and :443"]
            nat["NAT gateway + Elastic IP<br/>(in public_1)"]
        end

        subgraph priv["Private subnets private_1 / private_2 (2 AZs)"]
            subgraph eks["EKS cluster ac_app_&lt;env&gt;"]
                ng["Managed node group primary<br/>t4g.medium arm64, 1 to 2 nodes"]
                subgraph ns_app["namespace automation-calculator"]
                    ing["Ingress (class alb)"]
                    svc["Service NodePort :80 to :3000<br/>externalTrafficPolicy Local"]
                    pod["Rails pod :3000"]
                    sec["Secret automation-calculator-app-secrets"]
                end
                subgraph ns_sys["namespace kube-system"]
                    lbc["aws-load-balancer-controller"]
                    xdns["external-dns<br/>upsert-only, record-type TXT prefix"]
                    ms["metrics-server"]
                    kp["kube-proxy (EKS managed add-on)"]
                end
            end
            rds[("RDS PostgreSQL 16<br/>automation_calculator_app :5432")]
        end
    end

    subgraph obs["Monitoring"]
        cw["CloudWatch alarms ac-app-&lt;env&gt;-*<br/>ALB 5xx, target 5xx, p99 latency, unhealthy hosts"]
        sns["SNS topic ac-app-&lt;env&gt;-alarms"]
        mail(["Email subscriber"])
    end

    user -->|DNS lookup| r53
    user -->|HTTPS| alb
    igw --- alb
    acm -.->|TLS cert| alb
    alb -->|HTTP to NodePort on each node| ng
    ng --> svc --> pod
    pod -->|SQL :5432, SG allows only the EKS cluster SG| rds
    sec -.->|env vars| pod
    pod -->|egress| nat --> igw
    nat -.-> oauth
    ng -->|image pull via NAT| dockerhub

    lbc -->|IRSA: creates and updates ALB, target group, listeners| alb
    ing -.->|watched by| lbc
    ing -.->|hosts watched by| xdns
    xdns -->|IRSA: upserts A and TXT records| r53
    acm -.->|validation CNAMEs| r53
    alb -->|metrics| cw --> sns --> mail
```

Key elements:

- **Nodes and RDS are private.** Only the ALB and the NAT gateway live in the public subnets. Nodes reach Docker Hub and the OAuth providers through the single NAT gateway.
- **The ALB is not a Terraform resource.** The aws-load-balancer-controller creates it from the app's Ingress annotations (`load-balancer-name: ac-app-<env>`, `target-type: instance`, `certificate-arn` from ACM). The CloudWatch alarms find it and its target group by name and tags.
- **DNS records for the app hostnames are written by external-dns**, not Terraform. external-dns runs with `policy: upsert-only`, so it never deletes records. Terraform writes only the ACM validation records.
- **IRSA**: the controller and external-dns each assume their own IAM role (`<env>_eks_lb`, `<env>_eks_external_dns`) through the cluster's OIDC provider. No static AWS keys are used in the cluster.

## Global resources (`us-east-1`, production account)

```mermaid
flowchart LR
    subgraph ws["TFC workspace ac_app_production_route53_domains"]
        dio["Registered domain<br/>automation-calculations.io"]
        dnet["Registered domain<br/>automation-calculations.net"]
        zio[("Hosted zone .io")]
        znet[("Hosted zone .net")]
        hc["Route 53 health check<br/>apex HTTPS"]
        mx["MX record to Google mail"]
    end
    subgraph idc["IAM Identity Center (us-east-1)"]
        ps["Permission sets<br/>InfraEng&lt;Env&gt; and InfraEng&lt;Env&gt;ReadOnly"]
    end

    dio --> zio
    dnet --> znet --> mx
    hc -->|probes| zio
    zio -.->|records written per env by external-dns and ACM validation| envs["staging and production stacks"]
```

The permission sets are created by each environment's `base_cluster_layer` workspace through module `sso_infra_eng`, which uses a `us-east-1` provider alias.

## Who can touch what: human and CI access

```mermaid
flowchart LR
    eng(["Infra engineer<br/>Google Workspace identity"])
    sso["IAM Identity Center<br/>aws sso login"]
    rw["InfraEng&lt;Env&gt; SSO role"]
    ro["InfraEng&lt;Env&gt;ReadOnly SSO role"]
    ci["IAM role ac_ci_terraform_&lt;env&gt;"]
    ciro["IAM role ac_ci_terraform_&lt;env&gt;_read_only"]
    tfc(["Terraform Cloud workspace runs<br/>credentials held as TFC workspace variables"])
    admin["EKS access entry<br/>AmazonEKSClusterAdminPolicy"]
    view["EKS access entry<br/>AmazonEKSViewPolicy + group ac-ci-read-only<br/>(nodes read via ClusterRole)"]
    aws[("AWS APIs in the env account")]

    eng --> sso
    sso --> rw -->|sts:AssumeRole, trust matches SSO role ARN pattern| ci
    sso --> ro -->|sts:AssumeRole| ciro
    tfc --> ci
    ci --> admin
    ci --> aws
    ciro --> view
    ciro -->|describe, list, get only| aws
```

There are no IAM users or access keys for humans. Local `AWS_PROFILE`s chain SSO into the CI roles; see [docs/aws-sso-auth.md](../aws-sso-auth.md).

## Terraform layers and what each owns

```mermaid
flowchart TB
    tfcloud["terraform/env/&lt;env&gt;/tf_cloud<br/>creates the TFC workspaces"]
    base["ac_app_&lt;env&gt;_base_cluster_layer<br/>modules: networking, base-cluster-layer, ci-iam-role, sso-infra-eng"]
    addons["ac_app_&lt;env&gt;_cluster_addons_layer<br/>modules: cluster-addons-layer, main_rails_app<br/>+ helm/automation-calculator chart"]

    tfcloud -->|creates| base
    tfcloud -->|creates| addons
    base -->|run trigger after a successful apply| addons
    base -.->|tfe_outputs: VPC id, subnets, cluster name, OIDC provider| addons

    base --- b1["VPC, subnets, IGW, NAT, routes"]
    base --- b2["EKS cluster, node group, kube-proxy add-on, access entries"]
    base --- b3["CI IAM roles, SSO permission sets"]

    addons --- a1["Helm: ALB controller, external-dns, metrics-server<br/>+ their IRSA roles and service accounts"]
    addons --- a2["CloudWatch alarms, SNS topic"]
    addons --- a3["main_rails_app: app Helm release, RDS + SG + subnet group,<br/>ACM cert + Route 53 validation records"]
```

## How secrets reach the pod (key names only)

```mermaid
flowchart LR
    rp["random_password<br/>DB master password, secret_key_base"]
    tfv["TFC sensitive workspace variables<br/>GitHub and Google OAuth app id and secret"]
    rdsr[("RDS endpoint and db name")]
    hr["helm_release automation-calculator<br/>set_sensitive secrets.*"]
    ks["K8s Secret automation-calculator-app-secrets"]
    env["Pod env vars<br/>DATABASE_URL, SECRET_KEY_BASE,<br/>GITHUB_OAUTH_APP_ID / _SECRET,<br/>GOOGLE_OAUTH_APP_ID / _SECRET"]

    rp --> hr
    rdsr -->|composed into databaseUrl| hr
    tfv --> hr
    hr --> ks -->|secretKeyRef| env
```

Values live only in Terraform state, TFC workspace variables, and the cluster Secret. `helm/automation-calculator/values.yaml` holds placeholders.
