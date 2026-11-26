# --- From k8s/root.hcl --------------------------------------------------------------------

variable "env_name" {
  description = "Environment name (lab, CRGS00, ...)."
  type        = string
}

variable "dns_domain" {
  description = "Environment DNS domain. Builds the default Rancher hostname and AD server name."
  type        = string
}

# --- Rancher ------------------------------------------------------------------------------

variable "rancher_hostname" {
  description = "Name Rancher is served on. Default: rancher.<dns_domain>. Must match the rancher-server unit."
  type        = string
  default     = null
}

variable "certificate_dir" {
  description = "This environment's folder in the certificate tree on the control node, e.g. /srv/security/certificates/files/lab.local. Read: ca/ca.cert.pem, the internal root CA, which Rancher's certificate and the domain controllers' LDAPS certificates chain to."
  type        = string
}

variable "rancher_bootstrap_password" {
  description = "Rancher's first admin password (vault_rancher_bootstrap_password), the one the rancher-server unit installed. Used once, to log in and set rancher_admin_password. Export it as TF_VAR_rancher_bootstrap_password."
  type        = string
  sensitive   = true
}

variable "rancher_admin_password" {
  description = "The lasting password of Rancher's local admin (vault_rancher_admin_password). Export it as TF_VAR_rancher_admin_password."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.rancher_admin_password) >= 12
    error_message = "Set TF_VAR_rancher_admin_password to at least 12 characters."
  }
}

# --- Active Directory ---------------------------------------------------------------------

variable "ad_servers" {
  description = "Domain controllers Rancher queries over LDAPS. Default: [<dns_domain>], the same name Harbor uses. Their certificates must chain to the internal CA and cover this name."
  type        = list(string)
  default     = null
}

variable "ad_port" {
  description = "LDAPS port."
  type        = number
  default     = 636
}

variable "ad_default_login_domain" {
  description = "NetBIOS name of the domain (adcli info <domain> prints it as domain-short). Users then log in with their sAMAccountName alone, and the service and test accounts below are named the same way."
  type        = string
}

variable "ad_service_account_username" {
  description = "sAMAccountName of the read-only account Rancher binds with. The lab uses Harbor's svc_ldap_bind."
  type        = string
}

variable "ad_service_account_password" {
  description = "Its password (vault_harbor_ldap_bind_password for svc_ldap_bind). Export it as TF_VAR_ad_service_account_password."
  type        = string
  sensitive   = true
}

variable "ad_test_username" {
  description = "sAMAccountName of the account Rancher tests the login with. Rancher links this account to the local admin, so it becomes a Rancher administrator: use a dedicated account, never the bind account. It needs no AD group: the module allows it by name (ad_test_user_dn)."
  type        = string

  validation {
    condition     = lower(var.ad_test_username) != lower(var.ad_service_account_username)
    error_message = "ad_test_username must not be the bind account: Rancher makes the test account an administrator."
  }
}

variable "ad_test_user_dn" {
  description = "Distinguished name of the test account (Get-ADUser <name> | Select DistinguishedName). Its CN is often the display name, not the account name. Listed by name among the principals allowed to log in."
  type        = string
}

variable "ad_test_password" {
  description = "Its password (vault_rancher_ad_test_password). Export it as TF_VAR_ad_test_password."
  type        = string
  sensitive   = true
}

variable "ad_search_base" {
  description = "Where users and groups are searched, e.g. DC=lab,DC=local."
  type        = string
}

variable "ad_nested_groups" {
  description = "Follow nested group membership. Turn it on when users are in the admin or viewer group through other groups: with it off, Rancher reads only direct membership and refuses them (Permission denied). Logins are a little slower."
  type        = bool
  default     = false
}

# --- Access -------------------------------------------------------------------------------

variable "admin_group_dn" {
  description = "Distinguished name of the AD group whose members are Rancher administrators (global role admin)."
  type        = string
}

variable "viewer_group_dn" {
  description = "Distinguished name of the AD group whose members may log in and view every cluster, the Rancher cluster included."
  type        = string
}

variable "viewer_cluster_roles" {
  description = "Cluster role templates the viewer group gets in every cluster: through a global role for the downstream clusters, and one binding each in the Rancher (local) cluster. The defaults are Rancher's built-in read-only cluster roles."
  type        = list(string)
  default     = ["projects-view", "nodes-view", "clusterroletemplatebindings-view", "clustercatalogs-view"]
}

# --- Monitoring (kube-prometheus-stack and Rancher's dashboards) ---------------------------

variable "kubeconfig_path" {
  description = "Kubeconfig of the Rancher RKE2 cluster, written on the control node by the Ansible play rke2_rancher.yml. Used by the helm provider. Default: ~/.kube/<env_name>-rancher-cluster.yaml."
  type        = string
  default     = null
}

variable "monitoring_enabled" {
  description = "Install kube-prometheus-stack and rancher-monitoring-dashboards on the Rancher cluster."
  type        = bool
  default     = true
}

variable "kube_prometheus_stack_chart_path" {
  description = "Path of the kube-prometheus-stack chart on the control node, e.g. /repo/helm/charts/kube-prometheus-stack/kube-prometheus-stack-93.9.0.tgz (the mirror serves /repo)."
  type        = string
  default     = null

  validation {
    condition     = var.kube_prometheus_stack_chart_path == null || fileexists(pathexpand(coalesce(var.kube_prometheus_stack_chart_path, "/nonexistent")))
    error_message = "kube_prometheus_stack_chart_path doesn't point at a file. Put the chart (.tgz) on the mirror first."
  }
}

variable "monitoring_dashboards_chart_version" {
  description = "Version of rancher-monitoring-dashboards in Rancher's built-in catalog (rancher-charts). 110.x is the line for Rancher 2.15."
  type        = string
  default     = "110.0.1+up0.1.4"
}

variable "registry" {
  description = "Private registry (Harbor). Default: registry.<dns_domain>."
  type        = string
  default     = null
}

variable "monitoring_image_project" {
  description = "Harbor project holding the kube-prometheus-stack images, each under its source registry and path: <registry>/<project>/<source registry>/<path>, e.g. registry.lab.local/mirror/quay.io/prometheus/prometheus. mirror is the private project for every upstream image other than RKE2 and Rancher (docs/harbor.md)."
  type        = string
  default     = "mirror"
}

variable "grafana_admin_password" {
  description = "Password of Grafana's admin user (vault_rancher_grafana_admin_password). The chart's own default is public, so it is always replaced. Export it as TF_VAR_grafana_admin_password."
  type        = string
  sensitive   = true
  default     = null

  validation {
    condition     = var.grafana_admin_password == null || try(length(var.grafana_admin_password) >= 12, false)
    error_message = "Set TF_VAR_grafana_admin_password to at least 12 characters."
  }
}

variable "kube_prometheus_stack_extra_values" {
  description = "More kube-prometheus-stack values, merged over the module's by Helm (deep merge)."
  type        = any
  default     = {}
}

# --- Downstream cluster command-pro (custom, provisioned by Rancher) -----------------------

variable "app_cluster_enabled" {
  description = "Define the application cluster in Rancher. No nodes join until each runs the registration command (a later phase)."
  type        = bool
  default     = true
}

variable "app_cluster_name" {
  description = "Name of the application cluster in Rancher."
  type        = string
  default     = "command-pro"
}

variable "app_cluster_kubernetes_version" {
  description = "RKE2 version Rancher installs on the nodes. Must be in Rancher's release list (https://<rancher>/v1-rke2-release/releases)."
  type        = string
  default     = "v1.36.5+rke2r1"
}

variable "app_cluster_hostname" {
  description = "Name of the cluster's API on lb-app's virtual IP (DNS A record). Used for the TLS names and the Authorized Cluster Endpoint. Default: command-pro.<dns_domain>."
  type        = string
  default     = null
}

variable "app_cluster_tls_sans" {
  description = "Extra names and addresses in the API server certificate, besides app_cluster_hostname: lb-app's virtual IP."
  type        = list(string)
  default     = []
}

variable "app_cluster_cidr" {
  description = "Pod network, as in the Ansible role (rke2_cluster_cidr)."
  type        = string
  default     = "10.42.0.0/16"
}

variable "app_service_cidr" {
  description = "Service network, as in the Ansible role (rke2_service_cidr)."
  type        = string
  default     = "10.43.0.0/16"
}

variable "app_etcd_snapshot_schedule" {
  description = "etcd snapshot schedule (cron), as in the Ansible role."
  type        = string
  default     = "0 */6 * * *"
}

variable "app_etcd_snapshot_retention" {
  description = "etcd snapshots kept, as in the Ansible role."
  type        = number
  default     = 28
}

variable "registry_username" {
  description = "Harbor robot the cluster's nodes pull images as."
  type        = string
  default     = "robot$k8s-pull"
}

variable "harbor_k8s_pull_secret" {
  description = "Secret of that robot (vault_harbor_robot_secrets['k8s-pull']). Export it as TF_VAR_harbor_k8s_pull_secret."
  type        = string
  sensitive   = true
  default     = null
}

variable "app_cluster_ace_ca_file" {
  description = "File on the control node holding the application cluster's RKE2 server CA (/var/lib/rancher/rke2/server/tls/server-ca.crt on a node). Rancher puts it in the kubeconfig's direct context (Authorized Cluster Endpoint), because lb-app passes 6443 through and kubectl meets the API server's own certificate. The CA exists only once the first node has joined; leave null until then."
  type        = string
  default     = null

  validation {
    condition     = var.app_cluster_ace_ca_file == null || fileexists(pathexpand(coalesce(var.app_cluster_ace_ca_file, "/nonexistent")))
    error_message = "app_cluster_ace_ca_file doesn't point at a file. Copy server-ca.crt from a command-pro node first."
  }
}

variable "app_cluster_certificate_name" {
  description = "Folder and file prefix in certificate_dir of the certificate for app_cluster_hostname (command-pro/command-pro.{fullchain.crt,key}). It becomes the default certificate of RKE2's Traefik on the application cluster, the one served on 443 behind lb-app. The secret goes onto the running cluster, so set it once the first node has joined; null leaves Traefik's own default."
  type        = string
  default     = null
}
