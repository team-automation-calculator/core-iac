# Read-only access to the app database for people and agents
# (docs/db-read-only-access.md). Everything here is behind
# var.db_read_only_access_enabled, which also turns on IAM database
# authentication on the instance (main.tf).
#
# Three parts:
#   1. A Job that creates the read-only PostgreSQL roles. Terraform Cloud
#      cannot reach the database (private subnets, security group open to the
#      cluster only), so the SQL runs from a pod, as the master user the app
#      Secret already holds.
#   2. A TCP forwarder pod in its own namespace. It is the network path from a
#      laptop to the database: `kubectl port-forward` to it, and it relays to
#      the RDS endpoint. It holds no credential.
#   3. A Role that lets the read-only CI role port-forward to pods in that
#      namespace and nowhere else.
#
# The roles sign in with a 15-minute IAM token, never a password. Which AWS
# identity may ask for a token for which role is decided in the base layer:
# modules/aws/ci-iam-role (ac_read_only_ci_<env>) and modules/aws/sso-infra-eng
# (ac_read_only_infra_eng_<env>). The role names are repeated there and in
# scripts/db_read_only_psql.py; tests/test_db_read_only_psql.py checks that
# the four places agree.

locals {
  db_read_only_group_role     = "ac_read_only"
  db_read_only_ci_role        = "ac_read_only_ci_${var.environment_name}"
  db_read_only_infra_eng_role = "ac_read_only_infra_eng_${var.environment_name}"

  db_access_namespace = "ac-db-access"
  db_read_proxy_name  = "db-read-proxy"

  db_read_only_roles_sql = file("${path.module}/db_read_only_roles.sql")

  # The Job is immutable and runs once, so its name carries a hash of
  # everything that should make it run again: the SQL, the role names and the
  # database instance (a re-created empty instance has no roles).
  db_read_only_roles_job_hash = substr(sha256(join("\n", [
    local.db_read_only_roles_sql,
    local.db_read_only_group_role,
    local.db_read_only_ci_role,
    local.db_read_only_infra_eng_role,
    tostring(var.db_read_only_connection_limit),
    aws_db_instance.automation_calculator_app.resource_id,
  ])), 0, 10)

  db_read_proxy_config = templatefile("${path.module}/db_read_proxy_haproxy.cfg", {
    db_host = aws_db_instance.automation_calculator_app.address
    db_port = aws_db_instance.automation_calculator_app.port
  })
}

resource "kubernetes_config_map_v1" "db_read_only_roles" {
  count = var.db_read_only_access_enabled ? 1 : 0

  metadata {
    name      = "db-read-only-roles"
    namespace = kubernetes_namespace_v1.automation_calculator.metadata[0].name
  }

  data = {
    "db_read_only_roles.sql" = local.db_read_only_roles_sql
  }
}

# Lives in the app namespace because that is where the Secret with the master
# connection string is. ArgoCD prunes only what it tracks, so it leaves this
# Job alone, as it does the Secret.
resource "kubernetes_job_v1" "db_read_only_roles" {
  count = var.db_read_only_access_enabled ? 1 : 0

  metadata {
    name      = "db-read-only-roles-${local.db_read_only_roles_job_hash}"
    namespace = kubernetes_namespace_v1.automation_calculator.metadata[0].name
  }

  spec {
    backoff_limit = 2

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name" = "db-read-only-roles"
        }
      }

      spec {
        automount_service_account_token = false
        restart_policy                  = "Never"

        security_context {
          run_as_non_root = true
          run_as_user     = 70 # postgres in the alpine image
          run_as_group    = 70
        }

        container {
          name  = "psql"
          image = var.db_read_only_psql_image
          command = [
            "psql",
            "--no-psqlrc",
            "--set=ON_ERROR_STOP=1",
            "--set=group_role=${local.db_read_only_group_role}",
            "--set=ci_role=${local.db_read_only_ci_role}",
            "--set=infra_eng_role=${local.db_read_only_infra_eng_role}",
            "--set=connection_limit=${var.db_read_only_connection_limit}",
            "--file=/sql/db_read_only_roles.sql",
            "--dbname=$(DATABASE_URL)",
          ]

          env {
            name = "DATABASE_URL"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.app_secrets.metadata[0].name
                key  = "databaseUrl"
              }
            }
          }

          resources {
            requests = {
              cpu    = "10m"
              memory = "32Mi"
            }
            limits = {
              memory = "64Mi"
            }
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
            }
          }

          volume_mount {
            name       = "sql"
            mount_path = "/sql"
            read_only  = true
          }
        }

        volume {
          name = "sql"
          config_map {
            name = kubernetes_config_map_v1.db_read_only_roles[0].metadata[0].name
          }
        }
      }
    }
  }

  # A failed Job fails the apply, which is the point: without the roles the
  # rest of this file is a forwarder nobody can sign in through.
  wait_for_completion = true

  timeouts {
    create = "5m"
    update = "5m"
  }
}

resource "kubernetes_namespace_v1" "db_access" {
  count = var.db_read_only_access_enabled ? 1 : 0

  metadata {
    name = local.db_access_namespace
  }
}

# Both clusters run one node with 17 pod slots and little to spare
# (scripts/argocd_preflight.sh). A negative priority makes the forwarder the
# first pod the scheduler evicts when anything else needs its slot, and
# preemption_policy Never keeps it from evicting anything itself. So the
# forwarder can be Pending on a full node; it never costs another workload
# its place.
resource "kubernetes_priority_class_v1" "db_read_proxy" {
  count = var.db_read_only_access_enabled ? 1 : 0

  metadata {
    name = "ac-db-read-proxy"
  }

  description       = "Below every other pod: the database forwarder gives up its pod slot to anything that needs it."
  global_default    = false
  preemption_policy = "Never"
  value             = -1000
}

resource "kubernetes_config_map_v1" "db_read_proxy" {
  count = var.db_read_only_access_enabled ? 1 : 0

  metadata {
    name      = local.db_read_proxy_name
    namespace = kubernetes_namespace_v1.db_access[0].metadata[0].name
  }

  data = {
    "haproxy.cfg" = local.db_read_proxy_config
  }
}

# HAProxy in TCP mode: it relays bytes and never sees a credential, because
# the PostgreSQL session inside is TLS between the client and RDS. It gives no
# pod in the cluster anything new either: the database's security group
# already admits every pod on the nodes.
resource "kubernetes_deployment_v1" "db_read_proxy" {
  count = var.db_read_only_access_enabled ? 1 : 0

  metadata {
    name      = local.db_read_proxy_name
    namespace = kubernetes_namespace_v1.db_access[0].metadata[0].name
    labels = {
      "app.kubernetes.io/name" = local.db_read_proxy_name
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        "app.kubernetes.io/name" = local.db_read_proxy_name
      }
    }

    # No surge pod on a change: the node may have no slot for one.
    strategy {
      type = "Recreate"
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name" = local.db_read_proxy_name
        }
        annotations = {
          # Roll the pod when the configuration changes.
          "checksum/config" = sha256(local.db_read_proxy_config)
        }
      }

      spec {
        automount_service_account_token  = false
        priority_class_name              = kubernetes_priority_class_v1.db_read_proxy[0].metadata[0].name
        termination_grace_period_seconds = 5

        security_context {
          run_as_non_root = true
          run_as_user     = 99 # haproxy in the official image
          run_as_group    = 99
        }

        container {
          name  = "haproxy"
          image = var.db_read_proxy_image

          port {
            name           = "postgres"
            container_port = 5432
          }

          readiness_probe {
            tcp_socket {
              port = "postgres"
            }
            period_seconds = 10
          }

          resources {
            requests = {
              cpu    = "5m"
              memory = "24Mi"
            }
            limits = {
              memory = "64Mi"
            }
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
            }
          }

          volume_mount {
            name       = "config"
            mount_path = "/usr/local/etc/haproxy"
            read_only  = true
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map_v1.db_read_proxy[0].metadata[0].name
          }
        }
      }
    }
  }

  # Do not hold the apply for a pod that may rightly be Pending on a full
  # node (see the priority class above).
  wait_for_rollout = false
}

# The read-only CI role's EKS access entry carries the built-in view policy,
# which cannot port-forward. This adds that one verb, in this one namespace.
# Reaching the forwarder is not access to the data: the database still asks
# for an IAM token.
resource "kubernetes_role_v1" "db_read_proxy_port_forward" {
  count = var.db_read_only_access_enabled && var.ci_read_only_kubernetes_group != "" ? 1 : 0

  metadata {
    name      = "db-read-proxy-port-forward"
    namespace = kubernetes_namespace_v1.db_access[0].metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["pods/portforward"]
    verbs      = ["create"]
  }
}

resource "kubernetes_role_binding_v1" "db_read_proxy_port_forward" {
  count = var.db_read_only_access_enabled && var.ci_read_only_kubernetes_group != "" ? 1 : 0

  metadata {
    name      = "db-read-proxy-port-forward"
    namespace = kubernetes_namespace_v1.db_access[0].metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.db_read_proxy_port_forward[0].metadata[0].name
  }

  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Group"
    name      = var.ci_read_only_kubernetes_group
  }
}
