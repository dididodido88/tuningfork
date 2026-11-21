# Managed by Ansible (roles/rke2_server).
# kubectl, crictl and ctr shipped with RKE2. root also gets the node's admin kubeconfig.
case ":$PATH:" in
  *:/var/lib/rancher/rke2/bin:*) ;;
  *) PATH="$PATH:/var/lib/rancher/rke2/bin" ;;
esac
if [ "$(id -u)" -eq 0 ]; then
  export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
  export CRI_CONFIG_FILE=/var/lib/rancher/rke2/agent/etc/crictl.yaml
fi
