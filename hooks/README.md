# Certberus hooks

Custom scripts that run during various certificate lifecycle events.
Inspired by the `run-parts` pattern (like `/etc/cron.daily/`, `/etc/apt/apt.conf.d/`).

## How to use

1. Find the event you want to handle (see below)
2. Create an executable script in `/etc/certberus/hooks/<EVENT>.d/`
3. Name it `NN-description.sh` (e.g. `10-slack-notify.sh`) — the number controls order
4. `chmod +x /etc/certberus/hooks/<EVENT>.d/10-your-script.sh`

To disable: `chmod -x your-script.sh` or rename to `.disabled`.

## Events

### Lifecycle (called from certberus scripts)

| Event | When it runs | Can abort? |
|---|---|---|
| `pre-install` | Before `apt install` packages | YES (exit!=0 stops) |
| `post-install` | After package installation | NO (warning only) |
| `pre-snapshot` | Before /etc backup | YES |
| `post-snapshot` | After backup | NO |
| `pre-issue` | Before starting ACME request | YES |
| `post-issue` | After successful cert issuance | NO |
| `pre-deploy` | Before copying cert to its location | YES |
| `post-deploy` | After copy, before reload | NO |
| `pre-reload` | Before webserver reload | YES |
| `post-reload` | After reload (HTTPS verification, notifications) | NO |
| `on-failure` | Whenever something fails | NO |
| `on-rollback` | After rollback from snapshot | NO |

### mod_md-specific (Apache, proxied via MDMessageCMD)

| Event | Description |
|---|---|
| `renewing` | mod_md starts renewal |
| `renewed` | Renewal completed, but cert not yet installed |
| `installed` | New cert active (after graceful restart) |
| `expiring` | Cert approaching expiry (default: 30 days before) |
| `errored` | Error during renewal |
| `ocsp-renewed` | New OCSP response |
| `ocsp-errored` | OCSP failed |
| `challenge-setup` | mod_md preparing HTTP-01/TLS-ALPN-01 challenge |

## Available variables in hook scripts

Certberus exports these env variables to every hook script:

```bash
CA_EVENT           # event name (e.g. "post-issue")
CA_WEBSERVER       # apache | nginx | tomcat
CA_DOMAIN_LIST     # "example.com www.example.com" (space-separated)
CA_PRIMARY_DOMAIN  # "example.com"
CA_CERT_PATH       # absolute path to fullchain.pem (if known)
CA_KEY_PATH        # absolute path to privkey.pem
CA_CERT_ISSUER     # "Let's Encrypt" / "HARICA" / ...
CA_STAGING         # 0 or 1
CA_DRY_RUN         # 0 or 1
CA_LOG_FILE        # path to current log
CA_SNAPSHOT_PATH   # latest snapshot (for rollback)
CA_SOURCE          # "certberus" or "mod_md" (where the event was sent from)
```

## Examples

See `examples/` — copy a template and customize. All examples have the `.example` extension,
which `run-parts` ignores, so they can sit there without effect.

```bash
cp /etc/certberus/hooks/examples/post-issue/10-slack-notify.sh.example \
   /etc/certberus/hooks/post-issue.d/10-slack-notify.sh
chmod +x /etc/certberus/hooks/post-issue.d/10-slack-notify.sh
vi /etc/certberus/hooks/post-issue.d/10-slack-notify.sh   # fill in webhook URL
```

## Rules for writing hooks

- **Don't block** — hooks have `CB_HOOK_TIMEOUT` (default 60s), then SIGKILL
- **Idempotent** — the same event may fire multiple times (retry)
- **Silent success** — don't log too much, use `logger -t certberus-hook`
- **Exit codes:**
  - `0` = OK
  - `1` = warning (logged, continues)
  - `>=2` in `pre-*.d/` = FATAL, aborts pipeline
  - `>=2` in `post-*.d/` = warning (cert is already issued, can't undo)
- **Secrets** — don't store in hook scripts, read from `/etc/certberus/secrets.env` (mode 600)
