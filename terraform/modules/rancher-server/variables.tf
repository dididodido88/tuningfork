# --- From k8s/root.hcl --------------------------------------------------------------------

variable "env_name" {
  description = "Environment name (lab, CRGS00, ...). Builds the default kubeconfig path."
  type        = string
}

variable "dns_domain" {
  description = "Environment DNS domain. Builds the default Rancher hostname and registry name."
  type        = string
}

# --- Cluster access -----------------------------------------------------------------------

variable "kubeconfig_path" {
  description = "Kubeconfig of the Rancher RKE2 cluster, written on the control node by the Ansible play rke2_rancher.yml. Default: ~/.kube/<env_name>-rancher-cluster.yaml."
  type        = string
  default     = null
}

# --- Rancher ------------------------------------------------------------------------------

variable "chart_path" {
  description = "Local path of the downloaded Rancher chart, e.g. /srv/rancher/charts/rancher-2.12.3.tgz (docs/rancher.md)."
  type        = string

  validation {
    condition     = fileexists(pathexpand(var.chart_path))
    error_message = "chart_path doesn't point at a file. Download the Rancher chart (.tgz) to the control node first (ansible/docs/rancher.md)."
  }
}

variable "rancher_hostname" {
  description = "Name Rancher is served on (DNS A record to the load balancer's virtual IP). Default: rancher.<dns_domain>. Must match rancher_hostname in the Ansible inventory."
  type        = string
  default     = null
}

variable "registry" {
  description = "Private registry (Harbor) that holds every Rancher image under the project rancher/. Default: registry.<dns_domain>."
  type        = string
  default     = null
}

variable "replicas" {
  description = "Rancher pods. Default: one per cluster node (1 or 3), read from the cluster."
  type        = number
  default     = null
}

variable "rancher_bootstrap_password" {
  description = "Password of Rancher's first admin login. Set it in the shell as TF_VAR_rancher_bootstrap_password, never in a file. Rancher asks for a new one at first login."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.rancher_bootstrap_password) >= 12
    error_message = "Set TF_VAR_rancher_bootstrap_password to at least 12 characters."
  }
}

variable "helm_timeout" {
  description = "Seconds to wait for Rancher to roll out."
  type        = number
  default     = 900
}

variable "extra_values" {
  description = "More chart values, merged over the ones this module sets (top-level keys replace)."
  type        = any
  default     = {}
}

# --- TLS ----------------------------------------------------------------------------------

variable "certificate_dir" {
  description = "This environment's folder in the certificate tree on the control node, e.g. /srv/security/certificates/files/lab.local (certificates_env_dir in the Ansible inventory). Read: ca/ca.cert.pem and <certificate_name>/<certificate_name>.{fullchain.crt,key}."
  type        = string
}

variable "certificate_name" {
  description = "Folder and file prefix of the Rancher certificate in certificate_dir. The certificate must cover rancher_hostname."
  type        = string
  default     = "rancher"
}
