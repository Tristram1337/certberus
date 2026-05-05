# Certberus

Unified automation for **SSL/TLS certificate deployment** on Apache, nginx and Tomcat.
Podporuje Let's Encrypt, HARICA/CESNET TCS i ZeroSSL. Postaveno na bash a standardnim
Linux tooling — no Python / Go / Node.js, no daemon.

## Jeden script pro vsechno

```bash
# Interaktivni pruvodce (detekuje webserver, zepta se na detaily)
sudo certberus install

# Nebo non-interactive
sudo certberus issue --webserver apache --ca letsencrypt \
                     --email admin@example.com --domain foo.example.com
```

## Co to umi

| | Apache (mod_md) | nginx (certbot) | Tomcat 9+ (certbot) |
|---|:-:|:-:|:-:|
| Let's Encrypt | ✅ | ✅ | ✅ |
| HARICA / CESNET TCS (EAB) | ✅ | ✅ | ✅ |
| ZeroSSL (EAB) | ✅ | ✅ | ✅ |
| Staging (testovaci CA) | ✅ | ✅ | ✅ |
| Auto-detekce domen | ✅ (VirtualHost) | ✅ (server_name) | ✅ (Host name) |
| Snapshot pred zmenou | ✅ | ✅ | ✅ |
| Rollback pri chybe | ✅ | ✅ | ✅ (atomic cert swap) |
| Firewall auto-open (80/443) | ✅ | ✅ | ✅ |
| Auto-renewal | mod_md built-in | certbot.timer | certbot.timer |
| Custom pre/post hooks | ✅ | ✅ | ✅ |

## Architektura

```
certberus/
├── bin/certberus             # Mother orchestrator (install/issue/status/doctor/rollback)
├── lib/
│   ├── common.sh             # log, ask_yn, snapshot, trap, TTY
│   ├── os.sh                 # OS detect, pkg manager abstrakce
│   ├── dns.sh                # A+AAAA resolver, CAA check
│   ├── firewall.sh           # iptables/nftables/firewalld/ufw abstrakce
│   └── hooks.sh              # run-parts + mod_md MDMessageCMD adapter
├── webservers/
│   ├── apache-md.sh          # LE via mod_md (+ EAB mod)
│   ├── apache-md-eab.sh      # Wrapper pro HARICA/ZeroSSL
│   ├── nginx-certbot.sh      # webroot + deploy hook
│   └── tomcat-certbot.sh     # webroot + PEM keystore + atomic reload
├── hooks/
│   ├── README.md
│   └── examples/             # slack-notify, mail-admin, verify-https, …
├── config/
│   ├── config.env.example    # MINIMALNI (musi editovat admin)
│   └── advanced.env.example  # advanced (usually no need to touch)
└── install.sh                # instalator do /usr/local
```

Webserver moduly jsou spoustene **spawningem** (subprocess) z mother skriptu,
sdileji lib/ pres sourcing. Kazdy modul je pouzitelny samostatne (bez mother).

## Instalace

```bash
cd /root/certs/certberus
sudo ./install.sh

# Pak:
sudo $EDITOR /etc/certberus/config.env
sudo certberus install
```

## Konfigurace - dve vrstvy

**1. `/etc/certberus/config.env`** — minimum, co admin musi vyplnit (5 hodnot):
- `CB_EMAIL`
- `CB_CA` (letsencrypt | harica | zerossl)
- `CB_WEBSERVER` (auto | apache | nginx | tomcat)
- (HARICA/ZeroSSL): `CB_EAB_KID`, `CB_EAB_HMAC`
- (HARICA): per-account `CB_ACME_URL` nebo `CB_ACME_URL_HARICA`
- `CB_DOMAINS` (empty = autodetect from webserver configuration)

**2. `/etc/certberus/advanced.env`** — vsechny ostatni hodnoty zakomentovane,
vychozi hodnoty jsou rozumne. Admin odkomentuje jen to, co chce zmenit.

Stejne hodnoty jde nastavit i bez config souboru:

```bash
certberus issue --webserver nginx --domain example.com --email admin@example.com \
  --webroot /srv/acme --no-firewall

certberus issue --webserver tomcat --port80 webroot --set CB_TOMCAT_SSL_DIR=/srv/tomcat-ssl
```

For common options there are short flags. For advanced automation use the repeatable
`--set CB_NAME=value`, which accepts only `CB_*` variables.

## Hooks (run-parts pattern)

Custom scripts in `/etc/certberus/hooks/<event>.d/*.sh`:

| Event | When |
|---|---|
| `pre-issue`, `post-issue` | Before/after ACME request |
| `pre-deploy`, `post-deploy` | Before/after cert deployment |
| `pre-reload`, `post-reload` | Before/after webserver reload |
| `on-failure`, `on-rollback` | On error / after rollback |
| `renewing`, `renewed`, `installed`, `expiring`, `errored` | mod_md events (proxied from MDMessageCMD) |
| `ocsp-renewed`, `ocsp-errored`, `challenge-setup` | additional mod_md events |

Examples: `/etc/certberus/hooks/examples/` (slack-notify, mail-admin, verify-https, iptables ACME allow/revoke, …)

Env variables available in every hook: `CA_EVENT`, `CA_WEBSERVER`, `CA_PRIMARY_DOMAIN`, `CA_DOMAIN_LIST`, `CA_CERT_PATH`, `CA_KEY_PATH`, `CA_CERT_ISSUER`, `CA_STAGING`, `CA_LOG_FILE`, `CA_SNAPSHOT_PATH`, `CA_SOURCE`.

Viz `/etc/certberus/hooks/README.md`.

## Firewall

Auto-detection and opening 80/443 for:
- **firewalld** (RHEL/CentOS/Rocky)
- **ufw** (Ubuntu)
- **nftables** (Debian 12+)
- **iptables** (legacy i nf_tables backend)

For Tomcat, redirect 80→8080 is available (so Tomcat does not need to bind a privileged port).

With `CB_CA=harica` Certberus does not open the firewall by default. HARICA/CESNET EAB
often runs on a pre-validated domain set; if a specific account returns
HTTP-01 timeout, open 80/443 manually or set `CB_HARICA_FIREWALL_AUTO_OPEN=1`.

## Commands

```bash
certberus interactive  # interactive wizard
certberus auto          # production per config.env
certberus renew        # renew existing (idempotent)
certberus status       # overview of all certs
certberus doctor       # verify environment
certberus rollback     # restore from latest snapshot
certberus hooks list    # list installed hooks
```

## Supported OS

| OS | Apache | nginx | Tomcat |
|---|:-:|:-:|:-:|
| Debian 10 | ✅ | ✅ | ✅ |
| Debian 11 / 12 | ✅ | ✅ | ✅ |
| Ubuntu 18.04 | ⚠️ (Apache 2.4.29 < 2.4.34 - upgrade nutny) | ✅ | ✅ |
| Ubuntu 20.04 / 22.04 / 24.04 | ✅ | ✅ | ✅ |
| Rocky/AlmaLinux 8+ | (zatim netestovano, mela by fungovat) | | |

## Staging vs produkce

Pred produkcnim nasazenim vzdy otestuj se stagingem:

```bash
sudo certberus issue --staging --webserver apache ...
```

Staging CA nema rate-limity ale vystavuje certy, ktere prohlizec neuzna.
Pri prechodu na produkci skript automaticky vycisti staging data.

## Troubleshooting

```bash
# Detailni log
sudo tail -f /var/log/certberus/certberus.log

# Syslog
sudo journalctl -t certberus -f

# Syntax check vsech skriptu
for f in bin/certberus lib/*.sh webservers/*.sh; do bash -n "$f" && echo "OK: $f"; done

# Rollback
sudo certberus rollback
```

## Licence

Viz LICENSE.
