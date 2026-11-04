locals {
  www_redirect_name = "www.${var.automation_calculator_app_host}"
}

# ArgoCD migration Phase 4 (docs/argocd-migration-plan.md): Terraform owns the
# app namespace and the app Secret. The chart does not render the Secret
# (secrets.create is false in every values-<env>.yaml), so ArgoCD deploys the
# app from git alone without a secret value ever entering the repo.
#
# Both objects were created by Helm on the live clusters (create_namespace and
# the chart's templates/secret.yaml) and adopted into each env's state with
# `import` blocks in Phase 4 (runbook: docs/argocd-phase-4-secret-adoption.md;
# the import files were deleted in Phase 9 once both envs had applied them).
# Since Phase 9 this module manages only these two objects, RDS and ACM: the
# app's Helm release left Terraform in Phases 6 (staging) and 8 (production)
# and the ArgoCD Application in terraform/modules/kubernetes/argocd deploys the chart
# (docs/argocd-phase-9-decommission.md).
resource "kubernetes_namespace_v1" "automation_calculator" {
  metadata {
    name = "automation-calculator"
  }

  lifecycle {
    # Terraform sets nothing on the namespace but its name. Helm's
    # create_namespace created the live one bare (Kubernetes adds the
    # kubernetes.io/metadata.name label itself, and the provider already drops
    # *.kubernetes.io keys from state). Anything that labels or annotates the
    # namespace later, such as pod-security-admission labels applied by hand
    # or ArgoCD's CreateNamespace metadata, is not Terraform's to remove, so
    # the adoption and every later plan stay free of metadata churn.
    ignore_changes = [metadata[0].labels, metadata[0].annotations]
    # Deleting the namespace deletes the Ingress, and the ALB with it (the
    # top risk in docs/argocd-migration-plan.md). Any plan that would destroy
    # or replace it must fail instead. Note that this guard only holds while
    # the resource block exists: removing the block from the module plans a
    # destroy. Rollback is `terraform state rm`, never a revert that drops the
    # resource (docs/argocd-phase-4-secret-adoption.md).
    prevent_destroy = true
  }
}

resource "kubernetes_secret_v1" "app_secrets" {
  metadata {
    name      = "automation-calculator-app-secrets"
    namespace = kubernetes_namespace_v1.automation_calculator.metadata[0].name

    # Everything below mirrors what Helm left on the live Secret, so that the
    # Phase 4 import produced a clean plan. None of it is functional now that
    # Terraform owns the object. It is kept on purpose: the Helm metadata is
    # what would let a manual `helm upgrade --install` re-adopt the Secret if
    # the app ever had to go back to a Helm release (the rollback of last
    # resort in docs/argocd-phase-9-decommission.md), and dropping it would be
    # a metadata update on both live Secrets for no gain.
    annotations = {
      # Rendered by the chart since Phase 1 and applied by hand per its
      # runbook. It is also what made Helm leave the Secret in place when this
      # phase dropped it from the release manifest.
      "helm.sh/resource-policy" = "keep"
      # Helm 3.2+ stamps every object it installs or upgrades with the owning
      # release. Harmless now that the chart no longer renders the Secret:
      # Helm never looks at this object again.
      "meta.helm.sh/release-name"      = "automation-calculator"
      "meta.helm.sh/release-namespace" = "automation-calculator"
    }

    # The chart's common labels (templates/_helpers.tpl) as rendered by release
    # automation-calculator of chart automation-calculator 0.1.0 (appVersion
    # 1.0.0), plus the managed-by label Helm adds itself.
    #
    # app.kubernetes.io/instance is the one to watch: ArgoCD's *label* tracking
    # method treats any object carrying `app.kubernetes.io/instance: <Application
    # name>` as part of that Application and would prune it. ArgoCD 3.x, which
    # Phase 2 installed, tracks by annotation, so the label is inert; Phase 6
    # confirmed that with `argocd app resources` before enabling prune on
    # staging. Never switch application.resourceTrackingMethod to "label"
    # while this label is here.
    labels = {
      "app.kubernetes.io/instance"   = "automation-calculator"
      "app.kubernetes.io/managed-by" = "Helm"
      "app.kubernetes.io/name"       = "automation-calculator"
      "app.kubernetes.io/version"    = "1.0.0"
      "helm.sh/chart"                = "automation-calculator-0.1.0"
    }
  }

  type = "Opaque"

  # The six keys the chart's templates/secret.yaml rendered until Phase 4
  # (as stringData; the API server stores them as data, which is what this
  # attribute reads back), built from the same expressions the retired Helm
  # release's set_sensitive blocks used. The Deployment reads them through
  # secretKeyRef at pod start, so a changed value here takes effect on the
  # next rollout (an ArgoCD sync of a bump PR, or `kubectl rollout restart`),
  # not on apply.
  data = {
    databaseUrl          = "postgres://${aws_db_instance.automation_calculator_app.username}:${random_password.database_master_user_password.result}@${aws_db_instance.automation_calculator_app.endpoint}/${aws_db_instance.automation_calculator_app.db_name}"
    githubOAuthAppId     = var.github_oauth_app_id
    githubOAuthAppSecret = var.github_oauth_app_secret
    googleOAuthAppId     = var.google_oauth_app_id
    googleOAuthAppSecret = var.google_oauth_app_secret
    secretKeyBase        = random_password.rails_app_secret_key_base.result
  }
}

# The app's Helm release (helm_release.automation-calculator) lived here until
# ArgoCD migration Phase 9. It was never destroyed: each env's workspace ran
# `terraform state rm` on it (staging in Phase 6, production in Phase 8) and
# its Helm history was deleted, so the Service, Deployment and Ingress kept
# running and are reconciled by the ArgoCD Application since. Do not add a
# helm_release for the app back here: a `helm install` against the live
# objects would either fail or make two controllers fight over the Deployment
# (docs/argocd-phase-9-decommission.md explains the rollback of last resort).

resource "aws_security_group" "allow_db_access_from_eks" {
  name        = "allow_db_access_from_eks"
  description = "Allow DB Access from EKS"

  ingress {
    description     = "Allow DB Access from EKS"
    from_port       = var.db_port
    to_port         = var.db_port
    protocol        = "tcp"
    security_groups = var.db_security_group_ids
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Name = "Automation Calculator DB Access"
  }

  vpc_id = var.vpc_id
}

resource "aws_db_subnet_group" "db_access_subnet_group" {
  name       = "automation-calculator-db-access-subnet-group-${var.environment_name}"
  subnet_ids = var.db_subnet_group_ids
}

resource "aws_db_instance" "automation_calculator_app" {
  allocated_storage           = 10
  apply_immediately           = true
  allow_major_version_upgrade = true
  auto_minor_version_upgrade  = true
  db_name                     = "automation_calculator_app"
  db_subnet_group_name        = aws_db_subnet_group.db_access_subnet_group.name
  engine                      = "postgres"
  engine_version              = var.db_engine_version
  instance_class              = var.db_instance_class
  max_allocated_storage       = 64
  password                    = random_password.database_master_user_password.result
  port                        = var.db_port
  skip_final_snapshot         = true
  username                    = "automation_calculator_devops"
  vpc_security_group_ids = [
    aws_security_group.allow_db_access_from_eks.id,
  ]
}

resource "random_password" "database_master_user_password" {
  length  = 32
  special = false
}

resource "random_password" "rails_app_secret_key_base" {
  length  = 128
  special = false
  upper   = false
}

resource "aws_acm_certificate" "automation_calculator_app" {
  domain_name = var.automation_calculator_app_host
  subject_alternative_names = [
    local.www_redirect_name
  ]
  validation_method = "DNS"
}

data "aws_route53_zone" "automation_calculator_app" {
  name         = var.route53_zone_name
  private_zone = false
}

resource "aws_route53_record" "automation_calculator_app_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.automation_calculator_app.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.automation_calculator_app.zone_id
}

