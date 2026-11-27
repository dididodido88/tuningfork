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
