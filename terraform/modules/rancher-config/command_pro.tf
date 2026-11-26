# The application cluster, command-pro, defined in Rancher as a custom cluster: Rancher installs
# and manages RKE2 on each node once the node runs the cluster's registration command. Defining it
# joins no node; the app nodes are reinstalled without the standalone RKE2 and registered in a later
# phase (ansible/docs/app-cluster.md, section 6). Its settings follow the standalone cluster built
# by roles/rke2_server: same RKE2 version, Canal, networks, SELinux, etcd snapshots and registry.

locals {
  app_cluster_hostname = coalesce(var.app_cluster_hostname, "${var.app_cluster_name}.${var.dns_domain}")
}

# Harbor login for the nodes: Rancher writes it into each node's registries.yaml. The project
# rancher is private.
resource "rancher2_secret_v2" "app_registry_auth" {
  count = var.app_cluster_enabled ? 1 : 0

  cluster_id = "local"
  namespace  = "fleet-default"
  name       = "${var.app_cluster_name}-registry-auth"
  type       = "kubernetes.io/basic-auth"
  data = {
    username = var.registry_username
    password = var.harbor_k8s_pull_secret
  }

  lifecycle {
    precondition {
      condition     = var.harbor_k8s_pull_secret != null
      error_message = "The application cluster needs TF_VAR_harbor_k8s_pull_secret (vault_harbor_robot_secrets['k8s-pull'])."
    }
  }
}

resource "rancher2_cluster_v2" "app" {
  count = var.app_cluster_enabled ? 1 : 0

  name               = var.app_cluster_name
  kubernetes_version = var.app_cluster_kubernetes_version

  # Authorized Cluster Endpoint: Rancher's kubeconfig also gets a direct context to the cluster's
  # API through lb-app, which keeps working while Rancher is down.
  local_auth_endpoint {
    enabled  = true
    fqdn     = "${local.app_cluster_hostname}:6443"
    # The cluster's own RKE2 server CA: lb-app passes TLS through, so this is what the API server's
    # certificate chains to. Unknown until the first node joins (app_cluster_ace_ca_file).
    ca_certs = var.app_cluster_ace_ca_file == null ? null : file(pathexpand(var.app_cluster_ace_ca_file))
  }

  rke_config {
    # RKE2 settings on every node, as in roles/rke2_server/templates/config.yaml.j2. Images come
    # from Harbor through Rancher's systemDefaultRegistry.
    machine_global_config = yamlencode({
      cni            = "canal"
      selinux        = true
      "cluster-cidr" = var.app_cluster_cidr
      "service-cidr" = var.app_service_cidr
      "tls-san"      = distinct(concat([local.app_cluster_hostname], var.app_cluster_tls_sans))
    })

    etcd {
      snapshot_schedule_cron = var.app_etcd_snapshot_schedule
      snapshot_retention     = var.app_etcd_snapshot_retention
    }

    # As roles/rke2_server/templates/registries.yaml.j2: docker.io is mirrored to Harbor, and the
    # nodes log in to Harbor as the robot. They trust Harbor's certificate through the system CA
    # bundle, which holds the internal CA (roles/certificates).
    registries {
      mirrors {
        hostname  = "docker.io"
        endpoints = ["https://${local.registry}"]
      }
      mirrors {
        hostname  = local.registry
        endpoints = ["https://${local.registry}"]
      }
      configs {
        hostname                = local.registry
        auth_config_secret_name = rancher2_secret_v2.app_registry_auth[0].name
      }
    }
  }

  depends_on = [rancher2_auth_config_activedirectory.ad]
}
