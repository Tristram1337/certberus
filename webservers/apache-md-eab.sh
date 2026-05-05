#!/bin/bash
# certberus/webservers/apache-md-eab.sh
# Apache mod_md with ACME EAB (External Account Binding) - for HARICA / CESNET TCS / ZeroSSL.
# Thin wrapper around apache-md.sh that enforces EAB mode.
#
# Usage:
#   apache-md-eab.sh --ca harica --eab-kid KID --eab-hmac HMAC \
#                    --email admin@example.com [--domain foo.example.com]
#
set -u
_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

# Defaults for the most common case - HARICA / CESNET TCS
export CB_CA="${CB_CA:-harica}"
export CB_EAB_REQUIRED=1

# Hand control to the main script
exec "$_DIR/apache-md.sh" "$@"
