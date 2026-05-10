#!/bin/bash
# tests/unit/test-scan.sh - cb_scan inventory smoke test.
set -uo pipefail
CB_TEST_LIB_DIR="$(cd "$(dirname "$0")/../lib" && pwd)"
CB_REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/lib/assert.sh
source "$CB_TEST_LIB_DIR/assert.sh"
# shellcheck source=tests/lib/env.sh
source "$CB_TEST_LIB_DIR/env.sh"

t_require_tool openssl

SANDBOX="$(t_mktempdir scan)"
trap t_cleanup EXIT

# Sandbox structure: dir with cert + nginx-style config with reference
mkdir -p "$SANDBOX/etc/ssl" "$SANDBOX/etc/nginx"
CERT="$SANDBOX/etc/ssl/example.crt"
KEY="$SANDBOX/etc/ssl/example.key"
openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
    -subj "/CN=test.example.com" \
    -keyout "$KEY" -out "$CERT" >/dev/null 2>&1 \
    || { echo "openssl gen failed - skip"; exit 77; }

cat > "$SANDBOX/etc/nginx/site.conf" <<EOF
server {
    listen 443 ssl;
    ssl_certificate     $CERT;
    ssl_certificate_key $KEY;
}
EOF

# Stubs for logger; load common and scan
t_stub_log_helpers
# common.sh only has logger functions, no runtime needed; loading scan.sh is enough.
# shellcheck source=lib/scan.sh
CB_VERBOSE=0
source "$CB_REPO_ROOT/lib/scan.sh"

# Override default paths to sandbox; CB_SCAN_ROOT for config refs
export CB_SCAN_PATHS="$SANDBOX/etc"
export CB_SCAN_ROOT="$SANDBOX"

# ---- Test 1: TSV format finds our cert ------------------------------------
out_tsv=$(cb_scan --format tsv --no-listen 2>&1)
assert_contains "$out_tsv" "$CERT" "TSV output contains cert path"
assert_contains "$out_tsv" "test.example.com" "TSV output has CN"

# ---- Test 2: --no-fs skips FS section ------------------------------------
# (in TSV, FS rows are identified by "fs" in column 1; --no-fs skips them; path
# may still appear in config-refs)
out_nofs=$(cb_scan --format tsv --no-fs --no-config --no-listen 2>&1)
assert_not_contains "$out_nofs" "$CERT" "--no-fs+--no-config skips everything"

# ---- Test 3: config refs detect nginx ssl_certificate --------------------
out_cfg=$(cb_scan --format tsv --no-fs --no-listen 2>&1)
assert_contains "$out_cfg" "site.conf" "config-ref detects nginx site.conf"

# ---- Test 4: JSON format is valid ----------------------------------------
out_json=$(cb_scan --format json --no-listen 2>&1)
assert_contains "$out_json" "\"path\":" "JSON has path key"
# JSONL: each line is a standalone JSON object
first_line=$(echo "$out_json" | head -1)
[[ "$first_line" == "{"* && "$first_line" == *"}" ]] \
    && t_pass "JSON line has {} wrapper" \
    || t_fail "JSON line has no valid wrapper" "$first_line"

# Every line must be parseable
if command -v python3 >/dev/null 2>&1; then
    if echo "$out_json" | python3 -c '
import json,sys
for i, line in enumerate(sys.stdin):
    line = line.strip()
    if not line: continue
    json.loads(line)
' 2>/dev/null; then
        t_pass "JSONL lines parseable by python3"
    else
        t_fail "JSONL parse fail" "$(echo "$out_json" | head -5)"
    fi
fi

# ---- Test 5: unknown flag -> rc=2 -----------------------------------------
cb_scan --format bogus </dev/null >/dev/null 2>&1
rc=$?
assert_exit_code 2 "$rc" "invalid --format = rc 2"

cb_scan --bogus </dev/null >/dev/null 2>&1
rc=$?
assert_exit_code 2 "$rc" "unknown flag = rc 2"

# ---- Test 6: --help prints usage, rc=0 ------------------------------------
out_help=$(cb_scan --help 2>&1); rc=$?
assert_exit_code 0 "$rc" "--help rc 0"
assert_contains "$out_help" "format" "help mentions --format"

# ---- Test 7: password-protected certificates MUST NOT hang the scan ------
# Regression: before the v0.1.8 fix, 'certberus scan' hung when it hit
# a .p12 with a password -- openssl pkcs12 spawned an interactive prompt
# waiting on /dev/tty and the entire scan blocked.
PWPROT="$(t_mktempdir pwprot)"
# encrypted PEM private key (PKCS#8 with passphrase)
openssl genrsa 2048 2>/dev/null \
    | openssl pkcs8 -topk8 -v2 aes-256-cbc -passout pass:secret \
        -out "$PWPROT/encrypted.key.pem" 2>/dev/null
# locked p12 + open p12 + changeit p12
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=pw.test" \
    -keyout "$PWPROT/k.pem" -out "$PWPROT/c.pem" >/dev/null 2>&1
openssl pkcs12 -export -in "$PWPROT/c.pem" -inkey "$PWPROT/k.pem" \
    -passout pass:secret -out "$PWPROT/locked.p12" 2>/dev/null
openssl pkcs12 -export -in "$PWPROT/c.pem" -inkey "$PWPROT/k.pem" \
    -passout pass: -out "$PWPROT/open.p12" 2>/dev/null
openssl pkcs12 -export -in "$PWPROT/c.pem" -inkey "$PWPROT/k.pem" \
    -passout pass:changeit -out "$PWPROT/changeit.p12" 2>/dev/null

# CB_SCAN_PATHS to sandbox; CB_SCAN_ROOT empty so config refs do not search
# the main filesystem
CB_SCAN_PATHS_ORIG="$CB_SCAN_PATHS"
export CB_SCAN_PATHS="$PWPROT"
unset CB_SCAN_ROOT

# Run with a 15s timeout. Before the fix, the timeout expired = TEST FAIL.
# </dev/null is critical: this simulates cron / non-interactive execution where
# openssl prompt would fail with "could not read passphrase" instead of hanging, BUT
# the user had scan from a TTY so openssl found /dev/tty and blocked.
t_log() { :; } 2>/dev/null
t_log "scan on password-protected certs with 15s timeout"
START_TS=$(date +%s)
out_pw=$(timeout 15 bash -c '
    source "$1"
    cb_scan --format tsv --no-config --no-listen
' _ "$CB_REPO_ROOT/lib/scan.sh" </dev/null 2>&1)
rc_pw=$?
DUR=$(( $(date +%s) - START_TS ))

assert_exit_code 0 "$rc_pw" "scan completed over password-protected files (rc=0, not timeout)"
[[ "$DUR" -lt 15 ]] \
    && t_pass "scan finished under 15s ($DUR s) -- no prompt hang" \
    || t_fail "scan took $DUR s -- likely prompt hang"

# Correct classification
assert_contains "$out_pw" "pem-key-encrypted" "encrypted PEM key labeled as pem-key-encrypted"
assert_contains "$out_pw" "pkcs12-encrypted"  "locked.p12 labeled as pkcs12-encrypted"
# open.p12 (empty password) and changeit.p12 must be parsed
echo "$out_pw" | grep -q "open.p12.*pkcs12.*pw.test" \
    && t_pass "passwordless p12 parsed (CN=pw.test)" \
    || t_fail "passwordless p12 NOT parsed" "$(echo "$out_pw" | grep open.p12)"
echo "$out_pw" | grep -q "changeit.p12.*pkcs12.*pw.test" \
    && t_pass "changeit p12 parsed (CN=pw.test)" \
    || t_fail "changeit p12 NOT parsed" "$(echo "$out_pw" | grep changeit.p12)"

# Restore
export CB_SCAN_PATHS="$CB_SCAN_PATHS_ORIG"

t_summary
