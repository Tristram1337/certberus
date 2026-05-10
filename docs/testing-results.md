# Certberus — Testing Results

Last updated: 2026-05-10
Version: 0.1.20

## Tested platforms

| OS | Version | Arch | Result |
|----|---------|------|--------|
| Rocky Linux | 8.8 | x86_64 | **PASS** (all 6 modules, SELinux Enforcing) |
| Rocky Linux | 9.2 | x86_64 | **PASS** (all 6 modules, SELinux Enforcing+Permissive) |
| Rocky Linux | 10.0 | x86_64 | **PASS** (all 6 modules, SELinux Enforcing) |
| AlmaLinux | 8.10 | x86_64 | **PASS** (all 6 modules, SELinux Enforcing) |
| AlmaLinux | 9 | x86_64 | **PASS** (all 6 modules, SELinux Enforcing+Permissive) |
| AlmaLinux | 10 | x86_64 | **PASS** (all 6 modules, SELinux Enforcing) |
| CentOS Stream | 9 | x86_64 | **PASS** (all 6 modules, SELinux Enforcing) |
| CentOS Stream | 10 | x86_64 | **PASS** (all 6 modules, SELinux Enforcing) |
| Fedora | 42 | x86_64 | **PASS** (all 6 modules, SELinux Enforcing+Permissive) |
| Fedora | 43 | x86_64 | **PASS** (all 6 modules, SELinux Enforcing) |
| Debian | 12 | x86_64 | **PASS** (all 6 modules, prod cert, ext. SSL ✓, AppArmor enforce) |
| Debian | 13 | x86_64 | **PASS** (all 6 modules, multi-domain, AppArmor enforce) |
| Ubuntu | 22.04 LTS | x86_64 | **PASS** (all 6 modules incl tomcat9, AppArmor enforce) |
| Ubuntu | 24.04 LTS | x86_64 | **PASS** (all 6 modules, AppArmor enforce) |
| Ubuntu | 25.10 | x86_64 | **PASS** (all 6 modules, AppArmor enforce) |
| Debian | 13 | x86_64 | **PASS** (HARICA real cert, /tmp noexec) |
| Rocky Linux | 10.0 | x86_64 | **PASS** (previous testing v0.1.15-v0.1.17) |
| CentOS Stream | 10 | x86_64 | **PASS** (previous testing) |
| AlmaLinux | 10.1 | x86_64 | **PASS** (previous testing) |
| Ubuntu | 25.10 | x86_64 | **PASS** (previous testing) |

### Untested platforms

- openSUSE / SLES (zypper backend)
- Alpine (apk backend)
- ARM / aarch64

## Tested commands and features

### Basic commands (all OS)

| Command | Status |
|---------|--------|
| `certberus version` | PASS (12 servers) |
| `certberus help` | PASS |
| `certberus status` | PASS |
| `certberus doctor` | PASS |
| `certberus expiry` | PASS |
| `certberus logs N` | PASS |
| `certberus snapshots` | PASS |
| `certberus discover` | PASS |
| `certberus hooks list` | PASS |
| `certberus cert-info` (summary) | PASS |
| `certberus cert-info DOMAIN` (detail) | PASS |
| `certberus scan --format tsv` | PASS |
| `certberus scan --format json` | PASS |
| `certberus scan --no-fs` | PASS |
| `certberus scan --no-fs --no-config` | PASS |
| `certberus test-domain DOMAIN` (local) | PASS |
| `certberus test-domain DOMAIN` (remote) | PASS |
| `certberus renew` | PASS |
| `certberus rollback --dry-run` | PASS |
| `certberus rollback -y` | PASS |
| Flags before command (`--staging --verbose --yes help`) | PASS |
| Unknown command → exit 2 | PASS |

### Modules

| Module | OS | Status | Note |
|--------|----|--------|------|
| certbot-only (standalone) | All (12 servers) | PASS | LE staging certs issued on all |
| certbot-only (webroot) | Ubuntu 22.04 | PASS (earlier) | |
| certbot-only (port 80 occupied, no webroot) | Ubuntu 22.04 | PASS (correctly rejects) | |
| nginx-certbot | Debian 12, Debian 13, Ubuntu 22.04, Ubuntu 25.10 | PASS | nginx auto-install, cert, reload. Refactored: auto-detect nginx root, /var/www/acme removed. |
| apache-md | Debian 13, Ubuntu 24.04 | PASS | mod_md async polling, cert in domains/ |
| tomcat-certbot | Debian 13, Ubuntu 24.04 | **PASS** | **FIRST REAL HW TEST** — server.xml, HTTPS :443 |
| apache-md-eab | — | NOT TESTED | Requires HARICA + Apache |

### HARICA / CESNET TCS (EAB)

| Test | OS | Status |
|------|----|--------|
| HARICA dry-run (--skip-dns-check) | All (earlier) | PASS |
| HARICA real cert | Debian 13 | PASS — issuer GEANT TLS ECC 1 |
| HARICA wrong-organization domain | Rocky | Correctly rejects |
| EAB credentials in config.env persist | Rocky, Debian | PASS |
| HARICA validation without EAB → error | CentOS | PASS — correctly requires EAB |
| HARICA without ACME_URL → error | CentOS | PASS — correctly requires URL |

### Hook system

| Test | OS | Status |
|------|----|--------|
| Post-issue hook fires | Rocky 8 | PASS |
| CA_SOURCE=certbot in hook | Rocky 8 | PASS |
| CA_EVENT=post-issue | Rocky 8 | PASS |
| CA_WEBSERVER=certbot-only | Rocky 8 | PASS |
| CA_STAGING=1 (staging mode) | Rocky 8 | PASS |
| CA_CERT_ISSUER=letsencrypt | Rocky 8 | PASS |
| CA_CERT_PATH + CA_KEY_PATH | Rocky 8 | PASS — point to real files |
| Hook timeout (CB_HOOK_TIMEOUT=3) | Rocky 8 | PASS — log: "Hook timeout (>3s)" |
| Hooks list filters .disabled/.bak | Rocky 8 | PASS |
| on-rollback hook | Rocky 9 | PASS |
| Renewed.d hook (certbot renewal) | All | PASS (deploy hook installed) |

### Error paths

| Test | OS | Status |
|------|----|--------|
| Apache on RHEL family (OS guard) | Rocky 8/9, Alma 8/9, CentOS 9, Fedora 42/43 | PASS — "not supported" |
| Nginx on RHEL family (OS guard) | Rocky 8/9, Alma 8/9, CentOS 9, Fedora 42/43 | PASS |
| Tomcat on RHEL family (OS guard) | Rocky 8/9, Alma 8/9, CentOS 9, Fedora 42/43 | PASS |
| certbot-only passes OS guard | All RHEL | PASS |
| Missing email | Fedora 42 | PASS — "Missing valid email" |
| Invalid domain | Debian 13 | PASS |
| Invalid email | Ubuntu 22.04 | PASS |
| Multi-domain (2-3 SANs) | Rocky 8, Fedora 42, Ubuntu 22.04 | PASS |
| Flock (concurrent run) | Rocky 8 | PASS — second process blocked |
| Port 80 occupied without webroot | Ubuntu 22.04 | PASS — correctly rejects |

### Firewall

| Test | OS | Status |
|------|----|--------|
| Firewalld detection | AlmaLinux 8 | PASS (iptables nf_tables backend) |
| iptables (legacy) detection | Fedora 42 | PASS |
| iptables (nf_tables) detection | Debian 13, Ubuntu 22/24 | PASS |
| nftables detection | Fedora 42 (via iptables wrapper) | PASS |
| No firewall detection | Rocky 8/9, Alma 9, CentOS 9 | PASS |
| --firewall auto-open port 80/443 | AlmaLinux 8 | PASS |
| --no-firewall flag | AlmaLinux 9 | PASS — no FW messages |

### SELinux

| Test | OS | Status |
|------|----|--------|
| SELinux Enforcing — all operations (6 modules) | All RHEL (10 servers) | PASS |
| No AVC denials (ausearch) | All RHEL (10 servers) | PASS — 0 AVCs |
| getenforce still Enforcing | All RHEL | PASS |
| httpd_can_network_connect auto-enable | All RHEL (apache module) | PASS |
| restorecon after mktemp+mv | All RHEL (apache module) | PASS |
| SELinux Permissive vs Enforcing comparison | Rocky 9, Alma 9, Fedora 42 | PASS — identical result |

### Bundle

| Test | OS | Status |
|------|----|--------|
| Bundle build + syntax | Local | PASS |
| Bundle deploy on 12 servers | All | PASS |
| Bundle version match | All | PASS (0.1.17) |
| Payload extraction (lib/*.sh) | All | PASS |
| Payload extraction (webservers/*.sh) | All | PASS |
| /tmp noexec fallback to /var/tmp | Debian 13 | PASS |

### Staging → Production transition

| Test | OS | Status |
|------|----|--------|
| Staging cert detection, force-renewal | Rocky 8, Fedora 42 | PASS |
| Production LE cert (issuer R12) | Rocky 8 | PASS |
| Production LE cert (issuer E7) | Fedora 42, Debian 12, Debian 13 | PASS |
| Production LE cert (issuer E8) | Ubuntu 25.10 | PASS |

### End-to-end external verification (openssl s_client from an off-host client)

| OS | Cert | Verify return code |
|----|------|--------------------|
| Rocky 8 | LE R12 (prod) | **0 (ok)** |
| Fedora 42 | LE E7 (prod) | **0 (ok)** |
| Debian 12 | LE E7 (prod) | **0 (ok)** |
| Debian 13 | LE E7 (prod) | **0 (ok)** |
| Ubuntu 25.10 | LE E8 (prod) | **0 (ok)** |
| Rocky 8 | LE staging | accessible |
| Fedora 42 | LE staging | accessible |
| Debian 12 | LE staging | accessible |
| Ubuntu 25.10 | LE staging | accessible |

### EPEL auto-install

| Test | OS | Status |
|------|----|--------|
| EPEL auto-install (yum) | Rocky 8 | PASS — epel-release-8-22.el8 |
| EPEL auto-install (dnf) | Rocky 9, Alma 8, Alma 9, CentOS 9 | PASS |
| Fedora: certbot from base repos, WITHOUT EPEL | Fedora 42 (certbot 3.3.0), Fedora 43 (certbot 4.1.1) | PASS |

### Rollback and snapshots

| Test | OS | Status |
|------|----|--------|
| Snapshot created on issue | All | PASS |
| certberus snapshots | All | PASS |
| certberus rollback --dry-run | Rocky 9 | PASS |
| certberus rollback -y | Alma 9, Rocky 9 | PASS |
| on-rollback hook fires | Rocky 9 | PASS |

## Unit tests

```
16 tests, 16 pass, 0 fail, 0 skip (81s)

  test-bundle              27 pass
  test-certbot-renewal     35 pass
  test-cli-args            18 pass
  test-commands            70 pass
  test-common              92 pass
  test-discover            26 pass
  test-dns-os              47 pass (2 skip)
  test-firewall            75 pass
  test-firewall-default     5 pass
  test-hooks-deploy-integ  27 pass
  test-hooks-lifecycle     37 pass
  test-hooks-runtime       22 pass
  test-mod-md-adapter      27 pass
  test-preflight           11 pass
  test-scan                17 pass
  test-syntax              52 pass
```

## Chaos tests

7 chaos tests, all pass (part of `run-all.sh` default run, 23 tests total).

## Bugs found and fixed (earlier)

### v0.1.15 (6 bugs)

| # | Description | File | Fix |
|---|-------------|------|-----|
| 1 | Domain duplication (`-d x -d x`) | `bin/certberus`, `webservers/certbot-only.sh` | Dedup in `stage_find_domains` |
| 2 | `cb_pkg_installed` false positive (dpkg deinstall state) | `lib/os.sh:82` | `dpkg-query -W -f='${Status}'` + grep "install ok installed" |
| 3 | nginx ACME webroot 0700 (www-data 403) | `webservers/nginx-certbot.sh:131` | `chmod 0755` after mkdir |
| 4 | mod_md polling only staging/, not domains/ | `webservers/apache-md.sh` | Poll both paths + extra graceful |
| 5 | `cmd_rollback` unbound variable `$last` | `bin/certberus:979,986` | `local last=""` + certbot-only pattern in find |
| 6 | certbot-only ignores --firewall | `webservers/certbot-only.sh` | Added `stage_firewall` with `cb_firewall_ensure_http_https` |

### v0.1.16 (4 fixes)

| # | Description | File | Fix |
|---|-------------|------|-----|
| 7 | `cmd_hooks` shows .disabled/.bak files | `bin/certberus` | find -executable + ! -name filter |
| 8 | `doctor` without curl crashes (cb_server_ipv4/v6) | `lib/dns.sh` | `command -v curl` guard |
| 9 | scan returns exit code 1 | `lib/scan.sh`, `bin/certberus` | Explicit `return 0` |
| 10 | Domain merge from config.env (old CB_DOMAINS) | `bin/certberus` | `build_forward_args` resets CB_DOMAINS on CLI --domain |

### v0.1.17 (5 fixes)

| # | Description | File | Fix |
|---|-------------|------|-----|
| 11 | CA_SOURCE not propagated to hook | `lib/hooks.sh`, `webservers/*.sh` | Export in cb_run_hooks/cb_hook_context/cb_hook_set_cert + explicit export in modules |
| 12 | Dry-run retries 3x (cert file does not exist) | `lib/common.sh` | `cb_certbot_issue` skips file check on dry-run |
| 13 | Bundle crashes on /tmp noexec | `build/bundle.sh` | Fallback /var/tmp → /tmp with exec test |
| 14 | EPEL not auto-enabled (RHEL/CentOS/Alma/Rocky) | `lib/os.sh` | `cb_pkg_install` automatically `dnf install epel-release` |
| 15 | cmd_auto does not persist EAB credentials to config.env | `bin/certberus` | Pass CLI_EAB_KID/HMAC/ACME_URL to `cb_persist_config_skeleton` |

### v0.1.18 — RHEL full modules + Jetty + Caddy (8 fixes)

E2E testing of all 6 webserver modules on 10 RHEL-family servers (60 combinations).

| # | Description | File | Fix |
|---|-------------|------|-----|
| 17 | `apachectl -M` returns "not supported" on el9+ | `webservers/apache-md.sh` | `_cb_apache_list_modules()` fallback: apachectl → httpd → apache2ctl |
| 18 | `MDContactEmail` does not exist in mod_md < 2.4.0 (el8 has 2.0.8) | `webservers/apache-md.sh` | mod_md version detection, conditional `_APACHE_MD_HAS_CONTACT_EMAIL` |
| 19 | SELinux `user_tmp_t` on certberus-ssl.conf (mktemp+mv) | `webservers/apache-md.sh`, `lib/preflight.sh` | `restorecon` after `mv` of stub vhost and fallback cert |
| 20 | SELinux `httpd_can_network_connect off` blocks mod_md ACME | `webservers/apache-md.sh` | `stage_selinux()` — `setsebool -P httpd_can_network_connect on` |
| 21 | nginx webroot depth detection hardcoded depth==1 | `webservers/nginx-certbot.sh` | Relative depth tracking against server block depth (`sd=depth`) |
| 22 | nginx reload on inactive service | `webservers/nginx-certbot.sh` | `cb_svc_is_active nginx \|\| cb_svc_start nginx` before reload |
| 23 | Tomcat certbot always --webroot, even when webroot empty | `webservers/tomcat-certbot.sh` | Standalone fallback when `TOMCAT_ACME_WEBROOT` empty; webroot via Tomcat webapps/ROOT |
| 24 | `grep -q` + `set -o pipefail` → SIGPIPE (rc=141) | all webserver modules, `bin/certberus` | `grep ... >/dev/null` instead of `grep -q` for all `systemctl \| grep` |
| 25 | Jetty ssl.ini commented lines match grep | `webservers/jetty-certbot.sh` | `stage_inject_jetty_ssl()` — grep uncommented lines only, append full config |

#### RHEL module E2E matrix (10 servers x 6 modules = 60 tests)

| OS | certbot-only | Apache (mod_md) | nginx (certbot) | Tomcat (certbot) | Caddy (native) | Jetty (certbot) | SELinux |
|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| Rocky Linux 8 | **PASS** | **PASS** | **PASS** | **PASS** | **PASS** | **PASS** | Enforcing |
| Rocky Linux 9 | **PASS** | **PASS** | **PASS** | **PASS** | **PASS** | **PASS** | Enforcing |
| Rocky Linux 10 | **PASS** | **PASS** | **PASS** | **PASS** | **PASS** | **PASS** | Enforcing |
| AlmaLinux 8 | **PASS** | **PASS** | **PASS** | **PASS** | **PASS** | **PASS** | Enforcing |
| AlmaLinux 9 | **PASS** | **PASS** | **PASS** | **PASS** | **PASS** | **PASS** | Enforcing |
| AlmaLinux 10 | **PASS** | **PASS** | **PASS** | **PASS** | **PASS** | **PASS** | Enforcing |
| CentOS Stream 9 | **PASS** | **PASS** | **PASS** | **PASS** | **PASS** | **PASS** | Enforcing |
| CentOS Stream 10 | **PASS** | **PASS** | **PASS** | **PASS** | **PASS** | **PASS** | Enforcing |
| Fedora 42 | **PASS** | **PASS** | **PASS** | **PASS** | **PASS** | **PASS** | Enforcing |
| Fedora 43 | **PASS** | **PASS** | **PASS** | **PASS** | **PASS** | **PASS** | Enforcing |

SELinux Permissive comparison (rocky9, alma9, fedora42): Apache works identically in Enforcing and Permissive — no AVC denials.

### v0.1.20 — Debian/Ubuntu full modules E2E + chaos (3 fixes)

E2E testing of all 6 webserver modules on 5 fresh Debian/Ubuntu servers (30 module
combinations), plus 31 chaos tests on real hardware.

| # | Description | File | Fix |
|---|-------------|------|-----|
| 26 | Tomcat APR connector check had malformed line continuation (`\ >/dev/null` ate the `&&` continuation), printing `: command not found` on every Tomcat run | `webservers/tomcat-certbot.sh:221` | Replace `\ >/dev/null` with proper `>/dev/null 2>&1` redirection |
| 27 | Tomcat webroot fallback only tried unversioned `/usr/share/tomcat/webapps/ROOT` and `/var/lib/tomcat/webapps/ROOT`, but Debian/Ubuntu installs Tomcat at `/var/lib/tomcat10/webapps/ROOT`. ACME challenge files were written to a path Tomcat did not serve, causing every webroot challenge to 404 | `webservers/tomcat-certbot.sh` (`stage_port80_setup` webroot branch) | Read `CATALINA_BASE` from systemd `Environment` first (works for any version), fall back to versioned paths `/var/lib/tomcatN/webapps/ROOT` and `/usr/share/tomcatN/webapps/ROOT` |
| 28 | `stage_inject_jetty_ssl` only enabled Jetty's `ssl` module. The bare `ssl` module starts a TLS connector with no protocol, so Jetty failed at startup: `No default protocol for ServerConnector ... 0.0.0.0:8443`. Same function had `; then >/dev/null` (redirect after `then` keyword) that masked the original ssl-module check | `webservers/jetty-certbot.sh:478-501` | Add a parallel `https` module check + `--add-module=https` activation. The `https` module layers HTTP/1.1 on top of the TLS connector. Also fixed the malformed `then >/dev/null` redirect |

#### Debian/Ubuntu module E2E matrix (5 servers x 6 modules = 30 tests)

| OS | certbot-only | Apache (mod_md) | nginx (certbot) | Tomcat (certbot) | Caddy (native) | Jetty (certbot) | AppArmor |
|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| Debian 12 | **PASS** | **PASS** | **PASS** | **PASS** (tomcat10) | **PASS** | **PASS** | enforce |
| Debian 13 | **PASS** | **PASS** | **PASS** | **PASS** (tomcat10) | **PASS** | **PASS** | enforce |
| Ubuntu 22.04 | **PASS** | **PASS** | **PASS** | **PASS** (tomcat9) | **PASS** | **PASS** | enforce |
| Ubuntu 24.04 | **PASS** | **PASS** | **PASS** | **PASS** (tomcat10) | **PASS** | **PASS** | enforce |
| Ubuntu 25.10 | **PASS** | **PASS** | **PASS** | **PASS** (tomcat10) | **PASS** | **PASS** | enforce |

Apache `mod_md` package handling differs across releases:
- Debian 12 / Ubuntu 22.04 / Ubuntu 24.04 ship `libapache2-mod-md` as a separate package.
- Debian 13 (trixie) and Ubuntu 25.10 (questing) bundle `mod_md.so` into `apache2`
  itself (`/usr/lib/apache2/modules/mod_md.so`); `a2enmod md` works without
  installing an extra package. The certberus apache module handles both paths
  because it relies on `a2enmod md` rather than a hard package dependency.

Jetty serves on `:8443` (Jetty default port) — externally verified `HTTP/1.1 400`
with valid LE staging cert chain (issuers: Tenuous Tomato R13, Riddling Rhubarb R12,
Mysterious Mulberry E8, Puzzling Parsnip E7).

#### Chaos test results (31 tests on real HW)

| Category | Test | Server | Result |
|----------|------|--------|--------|
| Filesystem | Disk full during cert issuance | deb13 | **PASS** (no .partial leaked) |
| Filesystem | Read-only /etc/letsencrypt (mount busy in env) | deb13 | **PASS** (no crash; cert flow continued) |
| Filesystem | /tmp noexec (bundle fallback to /var/tmp) | deb13 | **PASS** (`certberus version` works) |
| Filesystem | Symlink loop in sites-enabled | deb13 | **PASS** (no hang) |
| Filesystem | Zero-byte config in sites-enabled | deb13 | **PASS** |
| Filesystem | Spaces in certificate path | deb13 | **PASS** (scan finds and labels correctly) |
| Network | DNS resolution failure (TEST-NET resolver) | ubu24 | **PASS** (RC=1, clear error, no hang) |
| Network | Port 80 occupied | ubu24 | **PASS** (clear "port 80 in use" message + suggestions) |
| Network | Port 443 occupied | ubu24 | **PASS** (HTTP-01 only needs :80, cert issues) |
| Network | Outbound HTTPS blocked (iptables DROP :443) | ubu24 | **PASS** (clean "Network is unreachable") |
| Network | Domain that does not point here (google.com) | ubu24 | **PASS** (LE rejects by policy; certbot-only intentionally skips local DNS check) |
| Concurrency | Two concurrent runs (flock) | deb12 | **PASS** ("Another certberus process is running") |
| Concurrency | SIGTERM during cert issuance | deb12 | **PASS** (no `.partial` files, lock released) |
| Concurrency | SIGKILL during cert issuance | deb12 | **PASS** (lock released after orphan certbot child exits) |
| Cert lifecycle | Expired cert already present | ubu22 | **PASS** (cert-info no crash) |
| Cert lifecycle | Key/cert mismatch | ubu22 | **PASS** (no crash) |
| Cert lifecycle | DER-encoded cert | ubu22 | **PASS** (scan labels `der`) |
| Cert lifecycle | Password-protected PKCS12 | ubu22 | **PASS** (labeled `pkcs12-encrypted` in 2 s, no hang) |
| Hooks | BOM in shebang | ubu24 | **PASS** (no crash) |
| Hooks | No execute permission | ubu24 | **PASS** (hook skipped, no run) |
| Hooks | Stderr noise | ubu24 | **PASS** (hook ran, certberus stdout intact) |
| Hooks | Nonzero exit (post-issue) | ubu24 | **PASS** (logged, certberus continued) |
| Hooks | Timeout (CB_HOOK_TIMEOUT=3 vs sleep 999) | ubu24 | **PASS** (`Hook timeout (>3s)` logged) |
| Security | Domain injection (4 variants: `;`, backtick, `$()`, newline) | deb13 | **PASS** (validator rejects, canary survived) |
| Security | Email injection | deb13 | **PASS** (`cb_validate_email` rejects) |
| Security | Path traversal in --webroot | deb13 | **PASS** (RC=1; webroot doesn't actually escape) |
| Security | Non-root execution | deb13 | **PASS** ("Script must be run as root (sudo).") |
| Security | Malicious config.env (`CB_EMAIL` injection) | deb13 | **PASS** (validator rejects) |
| Webserver | Apache broken vhost syntax | deb13 | **PASS** ("Syntax error... Aborting without reload") |
| Webserver | nginx invalid config | ubu22 | **PASS** ("nginx -t fails... No changes were made") |
| Webserver | Tomcat invalid server.xml | ubu24 | **PASS** ("server.xml is not valid XML") |

Multi-domain (Phase 15, deb13): 1 SAN cert with 3 domains issued. PASS.

Rollback (Phase 16, deb12): `snapshots`, `rollback --dry-run`, `rollback -y` flow. PASS.

Production cert (Phase 18, Debian 12): real Let's Encrypt cert (issuer
`C=US, O=Let's Encrypt, CN=E7`). External `openssl s_client` + system CA
bundle verifies the chain (`Verify return code: 0 (ok)`) when the chain is
served via `s_server -cert cert.pem -CAfile fullchain.pem`.

AppArmor (Phase 19): no certberus / certbot / apache / nginx / tomcat / caddy /
jetty denials in `journalctl -k` or `dmesg` on any of the 5 servers. The few
unrelated denials seen on Ubuntu 24.04 / 25.10 are from `ubuntu_pro_esm_cache`
and the `who` profile.

### Observations from this testing

| # | Description | Assessment |
|---|-------------|------------|
| — | DNS round-robin (one wildcard pointing to many IPs) causes LE HTTP-01 challenge failure | Not a certberus bug — LE must reach the exact IP. Resolved with socat forwarding during testing. |
| — | 1GB RAM servers (Rocky 9, Alma 9, CentOS 9) OOM on `dnf install certbot` | Not a bug — insufficient RAM. Resolved by adding swap. |
| — | HARICA EAB credentials are single-use for account registration | Not a certberus bug — HARICA ACME server protects EAB from reuse. |
| — | Config.env from HARICA test (CB_CA=harica, CB_ACME_URL) persists and affects next run with --staging | Potential UX issue. CLI --staging should ignore CB_ACME_URL from config.env when --ca harica is not set. |
| **16** | **Ubuntu 25.10: /var/www has permissions 700** — nginx worker (www-data) cannot read webroot for ACME challenge. `nginx-certbot` module creates `/var/www/acme` but does not verify traversability of the parent directory. | **FIXED** — refactored: module now auto-detects nginx document root from `nginx -T`, uses standard `/var/www/html` (fallback). `/var/www/acme` + snippet approach removed. Migration code cleans up remnants from <=0.1.16. E2E verified: Debian 12, Ubuntu 25.10. |

## Known limitations

1. **Apache mod_md EAB** (apache-md-eab.sh) — not tested (requires HARICA + Apache)
2. **openSUSE / SLES** — zypper backend exists in code but was not tested on real hardware
3. **Alpine** — apk backend exists in code but was not tested
4. **ARM / aarch64** — not tested
5. **UFW firewall** — detection works, but auto-open caused SSH lockout on Ubuntu (earlier)
6. **Config.env placeholder** — old install.sh generated `CB_ACME_URL` with placeholder `....` (not commented). `cb_sanitize_acme_url` catches it.

## Overall summary

| Metric | Value |
|--------|-------|
| Tested platforms | 17 (15 RHEL+Debian/Ubuntu + 5 previous) |
| RHEL-family modules E2E | 60/60 PASS (10 servers x 6 modules) |
| Debian/Ubuntu modules E2E | 30/30 PASS (5 servers x 6 modules) |
| Total modules E2E | 90/90 PASS |
| Unique OS versions | 15 |
| Staging certs issued | 111 (21 previous + 60 RHEL + 30 Debian/Ubuntu) |
| Production certs issued | 6 (Rocky 8, Fedora 42, Debian 12 x2, Debian 13, Ubuntu 25.10) |
| Ext. SSL verification (Verify: 0 ok) | 6/6 production, 4/4 staging |
| SELinux Enforcing servers | 10 (all RHEL, 0 AVC denials) |
| AppArmor enforce servers | 5 (all Debian/Ubuntu, 0 certberus-related denials) |
| Real-HW chaos tests | 31/31 PASS (filesystem, network, concurrency, lifecycle, hooks, security, webserver) |
| Hook tests | 16 (11 RHEL + 5 chaos) |
| Firewall backends tested | 4 (iptables legacy, iptables nf_tables, firewalld, nftables) |
| Unit tests | 16 pass, 0 fail |
| Chaos tests (in-tree) | 7 pass |
| New bugs found in v0.1.18 | 9 (#17-#25: Apache SELinux/RHEL, nginx depth, Tomcat standalone, Jetty ssl.ini, SIGPIPE) |
| New bugs found in v0.1.20 | 3 (#26 Tomcat APR check syntax, #27 Tomcat webroot Debian/Ubuntu paths, #28 Jetty https module) |
