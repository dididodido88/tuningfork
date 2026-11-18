# postfix_relay

Sets up a local Postfix relay on the SIEM VM. Wazuh, Alertmanager and Grafana hand their mail to
`localhost:25`, and Postfix forwards it to the environment's SMTP server.

Delivery is best effort: if the SMTP server is down, unset or refuses the mail, the mail waits in
the Postfix queue and is retried. The services that send it are never held up.

| | |
|---|---|
| Playbook | `playbooks/postfix_relay.yml` (also part of `playbooks/siem.yml`) |
| Hosts | `siem_servers` |
| Tag | `postfix_relay` |
| Needs first | `repositories` |
| Set variables in | `inventories/<ENV>/group_vars/all/siem.yml` (`siem_mail_*`), password in `group_vars/all/vault.yml` |
| Longer guide | [docs/siem.md](../../docs/siem.md) |

## What it does

1. Checks the settings, and tells you if no relay host is set (mail is then queued, not sent).
2. Installs Postfix, the SASL plain-login module and the `s-nail` mail client.
3. Writes the relay login to `/etc/postfix/sasl_passwd` (mode 0600) when a user name is set, or
   removes it when none is.
4. Sets `inet_protocols` in `/etc/postfix/main.cf` to match the host: `ipv4` when IPv6 is
   disabled (`linux_common_ipv6_enabled: false`, the default), `all` when it is enabled. This is
   written to the file directly, because with IPv6 disabled and the Postfix default (`all`),
   `postconf` itself fails with `no local interface found for ::1`.
5. Reads the current Postfix settings and changes only those that differ (`postconf -e`).
6. Enables and starts Postfix. It listens on loopback only.

## Variables

The defaults read the `siem_mail_*` values from the inventory, so you normally set those:

| Inventory variable | Role variable | Default | Description |
|---|---|---|---|
| `siem_mail_relay_host` | `postfix_relay_host` | `""` | SMTP server that mail is forwarded to. Empty: nothing is forwarded and mail stays queued. |
| `siem_mail_relay_port` | `postfix_relay_port` | `25` | Port of the SMTP server. |
| `siem_mail_relay_tls` | `postfix_relay_tls` | `may` | `none`: plain SMTP. `may`: STARTTLS when offered. `encrypt`: STARTTLS required, with the certificate checked. |
| `siem_mail_relay_username` | `postfix_relay_username` | `""` | SMTP login. Empty: no login. |
| `vault_postfix_relay_password` | `postfix_relay_password` | `""` | Password for the SMTP login. Required when a user name is set. |

Optional:

| Variable | Default | Description |
|---|---|---|
| `postfix_relay_ca_file` | `/etc/pki/tls/certs/ca-bundle.crt` | CA bundle the SMTP server's certificate is checked against. The system bundle holds the internal CA. |
| `postfix_relay_queue_lifetime` | `30d` | How long undeliverable mail is kept and retried. |
| `postfix_relay_packages` | `[postfix, cyrus-sasl-plain, s-nail]` | Packages to install. |

The `main.cf` settings the role manages are listed in `vars/main.yml` (`postfix_relay_settings`).
`inet_protocols` follows `linux_common_ipv6_enabled`.

## Example

```yaml
# inventories/<ENV>/group_vars/all/siem.yml
siem_mail_relay_host: smtp.lab.local
siem_mail_relay_port: 587
siem_mail_relay_tls: encrypt
siem_mail_relay_username: siem-relay

# inventories/<ENV>/group_vars/all/vault.yml (encrypted)
vault_postfix_relay_password: "<password>"
```

## Checking it

```sh
echo test | s-nail -s "relay test" you@example.internal   # send a test mail from the SIEM VM
mailq                                                     # mail still waiting
postqueue -f                                              # retry the queue now
```
