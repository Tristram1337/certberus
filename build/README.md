# certberus build & packaging

Builds are Docker-based — you don't need dpkg, rpmbuild, or apk-tools on the host. Just Docker.

## Quick start

```bash
# all formats
bash build/build.sh all

# just one
bash build/build.sh tarball
bash build/build.sh deb
bash build/build.sh rpm
bash build/build.sh apk
```

Output: `dist/certberus-<version>.<ext>`.

## Artifacts

| Format | File | Target | Installation |
|---|---|---|---|
| Tarball | `certberus-X.Y.Z.tar.gz` | any Linux | `tar xf … && cd … && sudo ./install.sh` |
| Debian | `certberus_X.Y.Z_all.deb` | Debian 11+, Ubuntu 20.04+ | `sudo apt install ./certberus_…deb` |
| RPM | `certberus-X.Y.Z-1.noarch.rpm` | RHEL 8+, Rocky, Alma, Fedora | `sudo dnf install ./certberus-…rpm` |
| APK | `certberus-X.Y.Z-r0.apk` | Alpine 3.18+ | `sudo apk add --allow-untrusted ./certberus-…apk` |

All are **noarch / architecture: all** — these are shell scripts.

## Runtime dependencies

Packages declare these dependencies (installed automatically):
- `bash` (≥ 4.0)
- `coreutils`, `grep`, `sed`, `gawk`
- `openssl`
- `curl`
- `bind9-dnsutils` / `bind-utils` (dig)
- `ca-certificates`

Depending on the branch (apache-md vs certbot), additional packages are needed:
- `apache2` + `libapache2-mod-md` (for Apache mod_md branch)
- `certbot` + plugin (for nginx/tomcat certbot branch)

These are NOT automatic package dependencies — install.sh and `certberus install` install them automatically based on the detected webserver, so Alpine/Rocky users don't pull Debian's apache2.

## CI/CD

`.github/workflows/release.yml` triggers all 4 builds in parallel matrix on `v*` tag push and uploads to GitHub Releases.

## Versioning

`build/VERSION` is the source of truth. `CB_VERSION` in `bin/certberus` is auto-updated via `build.sh sync-version`.
