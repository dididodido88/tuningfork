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
  description = "Follow nested group membership. Slower; leave off unless the groups below contain other groups."
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
