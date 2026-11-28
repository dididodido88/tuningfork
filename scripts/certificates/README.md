# Certificate scripts

These scripts build each environment's internal PKI on maestro, as root, outside Ansible and
Terraform. Everything they write goes under `/srv/security/certificates/files/<DOMAIN_NAME>/`.
The `certificates` role and the Terraform units under `terraform/k8s/` read the results from
there. Set `DOMAIN_NAME` (e.g. `lab.local`) before running any of them.

| Order | Script | Makes |
|---|---|---|
| 1 | `rootCA/init-root.ca.sh` | The self-signed root CA (20 years): `ca/private/ca.key.pem` (encrypted), `ca/ca.cert.pem`, the CA database (`index.txt`, `serial`), a copy of `openssl.cnf`, and `ca/ca.jks` |
| 2 | `host/generate_host_key_csr.sh` | A key and a CSR for each entry of `host/host.list`: `<CN>/<CN>.key`, `csr/<CN>.csr` |
| 3 | `host/sign.sh` | The root signs each entry of `host/sign.list` with its extension profile: `<CN>/<CN>.crt`, `.fullchain.crt`, `.p12` |
| 4 | `subCA/init-sub-ca.sh` | A subordinate CA for cert-manager on a Kubernetes cluster: `<SUBCA_NAME>/<SUBCA_NAME>.key`, `.crt`, `.fullchain.crt` |

## Folder layout

```
/srv/security/certificates/files/<DOMAIN_NAME>/
├── ca/                      root CA (key in private/, never leaves maestro)
├── <host>/                  one folder per host certificate
└── command-pro-ca/          cert-manager sub-CA of the application cluster
/srv/security/certificates/files/csr/   CSRs waiting to be signed
```

## The cert-manager sub-CA

cert-manager on the application cluster signs pods' certificates with its own CA, so the root's
key never enters the cluster. If the sub-CA's key leaks, only the sub-CA is replaced; the root and
every host certificate stay valid.

What the sub-CA may sign:
- **leaf certificates only** (`pathlen:0`);
- **only names in its permitted DNS domains** (critical name constraints; default `<DOMAIN_NAME>`,
  `cluster.local`, `svc`, each with its subdomains). A certificate for any other name fails
  validation;
- **only server and client authentication** (extended key usage).

```sh
DOMAIN_NAME=lab.local scripts/certificates/subCA/init-sub-ca.sh      # prompts for the root key's passphrase
```

Settings: `SUBCA_NAME` (default `command-pro-ca`), `SUBCA_CN`, `SUBCA_DAYS` (default 3650,
10 years, capped at the root's expiry) and `PERMITTED_DNS`. The header of the script lists them
all. The subject's C, ST and O are copied from the root, as the root's `policy_strict` requires.

- **The key is unencrypted**, because cert-manager reads it from a Kubernetes Secret, and the
  Terraform unit that creates that Secret keeps a copy in its local state. Keep both as
  protected as the vault.
- **The script never overwrites anything.** It records the issuance in the root's database and
  uses the same lock as `sign.sh`.
- **Lifetimes:** pods' certificates are 7 years, set by each Certificate's `duration`. A
  certificate must not outlive the CA that signed it, so renew the sub-CA before its last 7
  years begin, that is within 3 years of issue.
- **Renewal:** run the script again with a new `SUBCA_NAME` (e.g. `command-pro-ca-2029`), then
  point the Terraform unit at it. The root's database refuses a second certificate with the same
  subject, and `SUBCA_CN` defaults to one built from the name.

## Checking a certificate

```sh
openssl x509 -in <file>.crt -noout -subject -issuer -enddate -ext basicConstraints,nameConstraints,extendedKeyUsage
openssl verify -CAfile /srv/security/certificates/files/<DOMAIN_NAME>/ca/ca.cert.pem <file>.crt
```
