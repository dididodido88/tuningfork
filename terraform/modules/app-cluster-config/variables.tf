# --- From k8s/root.hcl --------------------------------------------------------------------

variable "env_name" {
  description = "Environment name (lab, CRGS00, ...). Builds the default kubeconfig path."
  type        = string
}

variable "dns_domain" {
  description = "Environment DNS domain. Builds the default registry and NFS server names."
  type        = string
}

# --- Cluster access and images ------------------------------------------------------------

variable "kubeconfig_path" {
  description = "Admin kubeconfig of the application cluster, written on the control node by the Ansible play rke2_app.yml after the first node joined. Default: ~/.kube/<env_name>-app-cluster.yaml."
  type        = string
  default     = null
}

variable "registry" {
  description = "Private registry (Harbor). Default: registry.<dns_domain>."
  type        = string
  default     = null
}

variable "image_project" {
  description = "Harbor project holding the upstream images, each under its source registry and path: <registry>/<project>/<source registry>/<path> (docs/harbor.md)."
  type        = string
  default     = "mirror"
}

# --- csi-driver-nfs and its storage classes -----------------------------------------------

variable "csi_driver_nfs_chart_path" {
  description = "Path of the csi-driver-nfs chart on the control node, e.g. /repo/helm/charts/csi-driver-nfs/csi-driver-nfs-4.13.6.tgz. null leaves the driver and its storage classes out."
  type        = string
  default     = null

  validation {
    condition     = var.csi_driver_nfs_chart_path == null || fileexists(pathexpand(coalesce(var.csi_driver_nfs_chart_path, "/nonexistent")))
    error_message = "csi_driver_nfs_chart_path doesn't point at a file. Put the chart on the mirror first."
  }
}

variable "nfs_server" {
  description = "NFS server the storage classes mount. Default: nas.<dns_domain>."
  type        = string
  default     = null
}

variable "nfs_mount_options" {
  description = "Mount options of every volume the storage classes create."
  type        = list(string)
  default     = ["nfsvers=4.2"]
}

variable "storage_classes" {
  description = "Storage classes of csi-driver-nfs. Each provisions into its share (a folder on the NFS server that must exist: the NAS creates it, nas_server_exports subdirs) and deletes a volume's folder with its claim (on_delete delete) or keeps it (retain). One may be the cluster's default."
  type = list(object({
    name                   = string
    share                  = string
    default                = optional(bool, false)
    reclaim_policy         = optional(string, "Delete")
    on_delete              = optional(string, "delete")
    allow_volume_expansion = optional(bool, false)
  }))
  default = []

  validation {
    condition     = length([for c in var.storage_classes : c if c.default]) <= 1
    error_message = "At most one storage class can be the default."
  }
}

# --- cert-manager and trust-manager -------------------------------------------------------

variable "cert_manager_chart_path" {
  description = "Path of the cert-manager chart on the control node, e.g. /repo/helm/charts/cert-manager/cert-manager-v1.21.3.tgz. null leaves cert-manager and trust-manager out."
  type        = string
  default     = null

  validation {
    condition     = var.cert_manager_chart_path == null || fileexists(pathexpand(coalesce(var.cert_manager_chart_path, "/nonexistent")))
    error_message = "cert_manager_chart_path doesn't point at a file. Put the chart on the mirror first."
  }
}

variable "trust_manager_chart_path" {
  description = "Path of the trust-manager chart on the control node, e.g. /repo/helm/charts/trust-manager/trust-manager-v0.26.0.tgz. Needs cert-manager. null leaves it out."
  type        = string
  default     = null

  validation {
    condition     = var.trust_manager_chart_path == null || fileexists(pathexpand(coalesce(var.trust_manager_chart_path, "/nonexistent")))
    error_message = "trust_manager_chart_path doesn't point at a file. Put the chart on the mirror first."
  }
}

variable "trust_manager_default_package" {
  description = "Load trust-manager's default package (Debian's public CA bundle, image trust-pkg-debian-trixie), which bundles can include with useDefaultCAs. Off: an air-gapped cluster trusts the internal CA, not public ones."
  type        = bool
  default     = false
}

variable "helm_timeout" {
  description = "Seconds to wait for each chart to roll out."
  type        = number
  default     = 600
}

# --- Rancher (monitoring dashboards and access), from terraform/k8s/<ENV>/rancher-config ------

variable "certificate_dir" {
  description = "This environment's folder in the certificate tree on the control node, e.g. /srv/security/certificates/files/lab.local. Read: ca/ca.cert.pem, the internal root CA, which Rancher's certificate chains to."
  type        = string
}

variable "rancher_url" {
  description = "Rancher Server address (rancher-config output url)."
  type        = string
}

variable "rancher_api_token" {
  description = "Rancher admin API token (rancher-config output api_token), read by Terragrunt from that unit's state."
  type        = string
  sensitive   = true
}

variable "app_cluster_id" {
  description = "Rancher's ID of this cluster, c-m-... (rancher-config output app_cluster_id)."
  type        = string
}

variable "viewer_group_principal" {
  description = "Principal of the AD group that may view every cluster (rancher-config output viewer_group). It gets View Monitoring in this cluster's System project."
  type        = string
}

# --- Monitoring: kube-prometheus-stack and rancher-monitoring-dashboards --------------------

variable "kube_prometheus_stack_chart_path" {
  description = "Path of the kube-prometheus-stack chart on the control node, e.g. /repo/helm/charts/kube-prometheus-stack/kube-prometheus-stack-93.9.0.tgz (the same chart as the Rancher cluster). null leaves monitoring out."
  type        = string
  default     = null

  validation {
    condition     = var.kube_prometheus_stack_chart_path == null || fileexists(pathexpand(coalesce(var.kube_prometheus_stack_chart_path, "/nonexistent")))
    error_message = "kube_prometheus_stack_chart_path doesn't point at a file. Put the chart on the mirror first."
  }
}

variable "monitoring_dashboards_chart_version" {
  description = "Version of rancher-monitoring-dashboards in Rancher's built-in catalog (rancher-charts). 110.x is the line for Rancher 2.15."
  type        = string
  default     = "110.0.1+up0.1.4"
}

variable "grafana_admin_password" {
  description = "Password of this cluster's Grafana admin user. The chart's own default is public, so it is always replaced. Export it as TF_VAR_grafana_admin_password."
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

# --- Issuer and trust bundle (certificates.tf) ------------------------------------------------

variable "issuer_ca_name" {
  description = "Name of the cluster's sub-CA made by scripts/certificates/subCA/init-sub-ca.sh (its SUBCA_NAME): certificate_dir/<name>/<name>.fullchain.crt and <name>.key. null: no ClusterIssuer."
  type        = string
  default     = null
}

variable "cluster_issuer_name" {
  description = "Name of the ClusterIssuer (type CA) backed by the sub-CA. Its secret is <name>-ca in the cert-manager namespace."
  type        = string
  default     = "internal-ca"
}

variable "trust_bundle_name" {
  description = "Name of trust-manager's Bundle, and of the ConfigMap it writes into every namespace with the internal root CA. Its source ConfigMap is <name>-source in the cert-manager namespace."
  type        = string
  default     = "internal-ca-bundle"
}

variable "trust_bundle_key" {
  description = "Key of the root CA in each namespace's trust ConfigMap."
  type        = string
  default     = "ca.crt"
}

variable "certificate_duration" {
  description = "Lifetime of the certificates cert-manager issues to pods (decided by the user: 7 years). cert-manager has no cluster-wide default, so every Certificate sets spec.duration to this, and every Ingress the annotation cert-manager.io/duration (module README). Hours, as cert-manager writes durations."
  type        = string
  default     = "61320h"

  validation {
    condition     = can(regex("^[0-9]+h$", var.certificate_duration))
    error_message = "certificate_duration is a number of hours, e.g. 61320h (7 years)."
  }
}
