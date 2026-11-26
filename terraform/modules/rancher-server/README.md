# Module `rancher-server`

Installs Rancher Server on the Rancher RKE2 cluster from the Helm chart on the mirror, and makes
the Rancher certificate the default certificate of the Traefik ingress controller that RKE2 ships.
It is called by `terraform/k8s/<ENV>/rancher-server`, which is applied by hand after Ansible has
built the cluster (`ansible/playbooks/rke2_rancher.yml`).

Guide: [ansible/docs/rancher.md](../../../ansible/docs/rancher.md) covers the downloads, the
images in Harbor and the run order. Every input is described in [variables.tf](variables.tf).

## What it creates

| Resource | What it is |
|---|---|
| `data.kubernetes_nodes.cluster` | Counts the nodes. The default `replicas` is one Rancher pod per node. |
| `kubernetes_secret_v1.traefik_default_certificate` | `kube-system/tls-default-certificate`: the Rancher certificate (full chain) and key, for Traefik |
| `kubernetes_manifest.traefik_config` | HelmChartConfig `kube-system/rke2-traefik`. It sets the chart value `tlsStore.default.defaultCertificate.secretName`, so the Traefik chart creates the TLSStore `default` with the secret above. |
| `kubernetes_namespace_v1.cattle_system` | The `cattle-system` namespace. Rancher's own labels and annotations on it are ignored. |
| `kubernetes_secret_v1.tls_rancher_ingress` | `tls-rancher-ingress`: the certificate (full chain) and key for the Rancher hostname, from the internal CA |
| `kubernetes_secret_v1.tls_ca` | `tls-ca`: the internal root CA. Rancher passes it to the agents of managed clusters. |
| `helm_release.rancher` | The Rancher chart, with the values below. It waits until Rancher has rolled out (`helm_timeout`). |

The two Traefik resources exist only while `traefik_default_certificate` is true (the default).
Traefik serves the default certificate to a request that names no host it knows, for example one
made to a node's address. Requests for `rancher.<domain>` get the same certificate through
Rancher's ingress either way.

**Chart values set by the module** (checked against the 2.15.3 chart):

| Value | Set to | Why |
|---|---|---|
| `hostname` | `rancher_hostname`, default `rancher.<dns_domain>` | DNS name on the lb-rancher virtual IP |
| `replicas` | one per node | One pod on each node |
| `bootstrapPassword` | `TF_VAR_rancher_bootstrap_password` | First admin login (vault: `vault_rancher_bootstrap_password`). Passed with `set_sensitive`, so the provider masks it in its debug log and the release metadata. |
| `networkExposure.type` | `ingress` | An Ingress, not the Gateway API |
| `ingress.ingressClassName` | `traefik` | The ingress controller that RKE2 ships, on host ports 80/443, which lb-rancher forwards to |
| `ingress.tls.source`, `ingress.tls.secretName` | `secret`, `tls-rancher-ingress` | Serve the internal CA certificate; no cert-manager |
| `privateCA` | `true` | The CA is in `tls-ca` |
| `systemDefaultRegistry` | `<registry>` | Every image comes from Harbor, Rancher's own included |
| `useBundledSystemChart` | `true` | System charts come from the Rancher image, not from Git |

`extra_values` is merged over these values; a top-level key replaces the module's value.

## Inputs you set in the unit

| Input | Example | Description |
|---|---|---|
| `chart_path` | `/repo/helm/charts/rancher/rancher-2.15.3.tgz` | The chart, on the mirror's folder on the control node |
| `certificate_dir` | `/srv/security/certificates/files/lab.local` | The environment's certificate folder (`certificates_env_dir` in the Ansible inventory). Reads `ca/ca.cert.pem` and `rancher/rancher.{fullchain.crt,key}` (`certificate_name`). |
| `env_name`, `dns_domain` | from `terraform/k8s/root.hcl` | Build the defaults below |

Defaults you can override: `kubeconfig_path` (`~/.kube/<env_name>-rancher-cluster.yaml`, written
by Ansible), `rancher_hostname`, `registry`, `replicas`, `certificate_name`, `helm_timeout`,
`traefik_default_certificate`.

## Providers

`hashicorp/helm` v3 and `hashicorp/kubernetes` ([versions.tf](versions.tf)), from the local plugin
directory. Both connect through the kubeconfig that Ansible wrote on the control node. Its server is
`https://<rancher hostname>:6443`, through the load balancer.

## Outputs

`url` (`https://<hostname>/`), `replicas`, `chart_version` (the deployed chart) and
`traefik_default_certificate` (the secret, or null when off).

## Security

The local state holds the certificate's private key and the bootstrap password. Keep
`terraform/state/` as protected as the Ansible vault.
