# Module `rancher-server`

Installs Rancher Server on the Rancher RKE2 cluster from the downloaded Helm chart. It is called
by `terraform/k8s/<ENV>/rancher-server`, which is applied by hand after Ansible has built the
cluster (`ansible/playbooks/rke2_rancher.yml`).

Guide: [ansible/docs/rancher.md](../../../ansible/docs/rancher.md) covers the downloads, the
images in Harbor and the run order. Every input is described in [variables.tf](variables.tf).

## What it creates

| Resource | What it is |
|---|---|
| `data.kubernetes_nodes.cluster` | Counts the nodes. The default `replicas` is one Rancher pod per node. |
| `kubernetes_namespace_v1.cattle_system` | The `cattle-system` namespace. Rancher's own labels and annotations on it are ignored. |
| `kubernetes_secret_v1.tls_rancher_ingress` | `tls-rancher-ingress`: the certificate (full chain) and key for the Rancher hostname, from the internal CA |
| `kubernetes_secret_v1.tls_ca` | `tls-ca`: the internal root CA. Rancher passes it to the agents of managed clusters. |
| `helm_release.rancher` | The Rancher chart, with the values below. It waits until Rancher has rolled out (`helm_timeout`). |

**Chart values set by the module:**

| Value | Set to | Why |
|---|---|---|
| `hostname` | `rancher_hostname`, default `rancher.<dns_domain>` | DNS name on the lb-rancher virtual IP |
| `replicas` | one per node | One pod on each node |
| `bootstrapPassword` | `TF_VAR_rancher_bootstrap_password` | First admin login; Rancher asks for a new password |
| `ingress.ingressClassName` | `traefik` | The ingress controller that RKE2 ships, on host ports 80/443, which lb-rancher forwards to |
| `ingress.tls.source` | `secret` | Serve `tls-rancher-ingress`; no cert-manager |
| `privateCA` | `true` | The CA is in `tls-ca` |
| `rancherImage`, `systemDefaultRegistry` | `<registry>/rancher/rancher`, `<registry>` | Every image comes from Harbor |
| `useBundledSystemChart` | `true` | System charts come from the Rancher image, not from Git |

`extra_values` is merged over these values; a top-level key replaces the module's value.

## Inputs you set in the unit

| Input | Example | Description |
|---|---|---|
| `chart_path` | `/srv/rancher/charts/rancher-<version>.tgz` | The chart, copied to the control node |
| `certificate_dir` | `/srv/security/certificates/files/lab.local` | The environment's certificate folder (`certificates_env_dir` in the Ansible inventory). Reads `ca/ca.cert.pem` and `rancher/rancher.{fullchain.crt,key}`. |
| `env_name`, `dns_domain` | from `terraform/k8s/root.hcl` | Build the defaults below |

Defaults you can override: `kubeconfig_path` (`~/.kube/<env_name>-rancher-cluster.yaml`, written
by Ansible), `rancher_hostname`, `registry`, `replicas`, `certificate_name`, `helm_timeout`.

## Providers

`hashicorp/helm` v3 and `hashicorp/kubernetes` ([versions.tf](versions.tf)), from the local plugin
directory. Both connect through the kubeconfig that Ansible wrote on the control node. Its server is
`https://<rancher hostname>:6443`, through the load balancer.

## Outputs

`url` (`https://<hostname>/`), `replicas`, and `chart_version` (the deployed chart).

## Security

The local state holds the certificate's private key and the bootstrap password. Keep
`terraform/state/` as protected as the Ansible vault.
