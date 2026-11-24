# Rancher's own configuration, after the rancher-server unit has installed it:
#   1. the local admin's lasting password and the server URL (rancher2_bootstrap);
#   2. Active Directory login over LDAPS, restricted to two AD groups;
#   3. what those groups may do: the admin group administers Rancher, and the viewer group may
#      log in and view every cluster, the Rancher (local) cluster included.
#
# The local state holds the admin password and token, the bind and test passwords: keep
# terraform/state/ as protected as the Ansible vault.

locals {
  hostname   = coalesce(var.rancher_hostname, "rancher.${var.dns_domain}")
  api_url    = "https://${local.hostname}"
  ca_cert    = file("${var.certificate_dir}/ca/ca.cert.pem")
  ad_servers = coalesce(var.ad_servers, [var.dns_domain])

  # Rancher names AD groups by their distinguished name.
  admin_group_principal  = "activedirectory_group://${var.admin_group_dn}"
  viewer_group_principal = "activedirectory_group://${var.viewer_group_dn}"
  test_user_principal    = "activedirectory_user://${var.ad_test_user_dn}"
}

# --- 1. Admin password and server URL -----------------------------------------------------
resource "rancher2_bootstrap" "admin" {
  provider = rancher2.bootstrap

  initial_password = var.rancher_bootstrap_password
  password         = var.rancher_admin_password
}

# --- 2. Active Directory login --------------------------------------------------------------
# Rancher checks the settings by logging in as the test account before it turns AD on, and links
# that account to the local admin, which makes it an administrator. Only members of the two groups
# may log in (restricted), plus the test account by name: it is in no AD group, so that it opens
# no other system, and Rancher adds it to the allowed list itself, which would drift if it weren't
# listed here. The local admin keeps working as the break-glass login.
resource "rancher2_auth_config_activedirectory" "ad" {
  servers     = local.ad_servers
  port        = var.ad_port
  tls         = true
  start_tls   = false
  certificate = local.ca_cert

  default_login_domain     = var.ad_default_login_domain
  service_account_username = var.ad_service_account_username
  service_account_password = var.ad_service_account_password
  test_username            = var.ad_test_username
  test_password            = var.ad_test_password

  user_search_base                = var.ad_search_base
  group_search_base               = var.ad_search_base
  nested_group_membership_enabled = var.ad_nested_groups

  access_mode           = "restricted"
  allowed_principal_ids = [local.admin_group_principal, local.viewer_group_principal, local.test_user_principal]
}

# --- 3. What the groups may do --------------------------------------------------------------

# Admin group: Rancher administrators.
resource "rancher2_global_role_binding" "admins" {
  name               = "ad-admins-admin"
  global_role_id     = "admin"
  group_principal_id = local.admin_group_principal

  depends_on = [rancher2_auth_config_activedirectory.ad]
}

# Viewer group: may log in (user-base) ...
resource "rancher2_global_role_binding" "viewers_login" {
  name               = "ad-viewers-user-base"
  global_role_id     = "user-base"
  group_principal_id = local.viewer_group_principal

  depends_on = [rancher2_auth_config_activedirectory.ad]
}

# ... and view every downstream cluster: a global role's inherited cluster roles apply in every
# cluster except the local one, including clusters added later.
resource "rancher2_global_role" "cluster_viewer" {
  name                    = "Cluster Viewer"
  description             = "Read-only view of every downstream cluster (Terraform: k8s/${var.env_name}/rancher-config)"
  new_user_default        = false
  inherited_cluster_roles = var.viewer_cluster_roles
}

resource "rancher2_global_role_binding" "viewers_clusters" {
  name               = "ad-viewers-cluster-viewer"
  global_role_id     = rancher2_global_role.cluster_viewer.id
  group_principal_id = local.viewer_group_principal

  depends_on = [rancher2_auth_config_activedirectory.ad]
}

# ... and view the local cluster too, which inherited cluster roles leave out: the same roles,
# bound in that cluster directly.
resource "rancher2_cluster_role_template_binding" "viewers_local" {
  for_each = toset(var.viewer_cluster_roles)

  name               = "ad-viewers-${each.value}"
  cluster_id         = "local"
  role_template_id   = each.value
  group_principal_id = local.viewer_group_principal

  depends_on = [rancher2_auth_config_activedirectory.ad]
}
