#!/bin/bash
# tests/unit/test-certbot-renewal.sh
# Tests for _cb_read_certbot_renewal (nginx-certbot.sh)
# and _cb_tomcat_restore_root_context (tomcat-certbot.sh).
#
# We do not source entire webserver scripts (they pull in lib/common.sh etc.),
# but define the tested functions locally with sandbox paths.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/assert.sh"
source "$HERE/../lib/env.sh"

t_stub_log_helpers
SANDBOX=$(t_mktempdir)
trap 't_cleanup' EXIT
t_isolate_cb_dirs "$SANDBOX"

# ============================================================================
# Helper: sandbox version of _cb_read_certbot_renewal
# Instead of /etc/letsencrypt/renewal/ reads from $SANDBOX/letsencrypt/renewal/
# ============================================================================
_RENEWAL_DIR="$SANDBOX/letsencrypt/renewal"
mkdir -p "$_RENEWAL_DIR"

_cb_read_certbot_renewal() {
    local domain="$1"
    local conf="$_RENEWAL_DIR/${domain}.conf"
    [[ -f "$conf" && -s "$conf" ]] || return 1

    local auth="" wrpath=""
    auth=$(grep -E '^\s*authenticator\s*=' "$conf" 2>/dev/null | head -1 | sed 's/.*=\s*//' | tr -d '[:space:]')

    if [[ "$auth" == "webroot" ]]; then
        wrpath=$(awk '
            /^\[\[webroot\]\]/ { in_wr=1; next }
            /^\[/              { in_wr=0 }
            in_wr && /=/ {
                sub(/^[^=]*=\s*/, "")
                gsub(/[[:space:],]/, "")
                print
                exit
            }
        ' "$conf" 2>/dev/null)
        [[ -z "$wrpath" ]] && wrpath=$(grep -E '^\s*webroot_path\s*=' "$conf" 2>/dev/null | head -1 | sed 's/.*=\s*//' | tr -d '[:space:]' | tr -d ',')
    fi

    printf '%s\n%s\n' "$auth" "$wrpath"
    return 0
}

# ============================================================================
# Helper: sandbox version of _cb_tomcat_restore_root_context
# Uses $TOMCAT_CONF_DIR from variable (set to sandbox).
# ============================================================================
TOMCAT_CONF_DIR="$SANDBOX/tomcat-conf"
_CB_TOMCAT_ORIG_ROOT_XML=""

_cb_tomcat_restore_root_context() {
    local ctx_dir="$TOMCAT_CONF_DIR/Catalina/localhost"
    local root_xml="$ctx_dir/ROOT.xml"
    [[ -f "$root_xml" ]] || return 0
    if grep -q 'certberus' "$root_xml" 2>/dev/null || grep -q 'docBase="/var/www/acme"' "$root_xml" 2>/dev/null; then
        if [[ -n "$_CB_TOMCAT_ORIG_ROOT_XML" && -f "$_CB_TOMCAT_ORIG_ROOT_XML" ]]; then
            mv "$_CB_TOMCAT_ORIG_ROOT_XML" "$root_xml"
            cb_ok "ROOT.xml restored from backup"
        else
            rm -f "$root_xml"
            cb_ok "Temporary ACME ROOT.xml removed"
        fi
    fi
}

# ============================================================================
# Helper function to reset Tomcat sandbox before each test
# ============================================================================
_reset_tomcat_sandbox() {
    rm -rf "$TOMCAT_CONF_DIR"
    mkdir -p "$TOMCAT_CONF_DIR/Catalina/localhost"
    _CB_TOMCAT_ORIG_ROOT_XML=""
}

# ============================================================================
# Tests for _cb_read_certbot_renewal
# ============================================================================
t_info "=== _cb_read_certbot_renewal ==="

# Test 1: webroot authenticator with [[webroot]] section
cat > "$_RENEWAL_DIR/webroot-basic.conf" <<'EOF'
[renewalparams]
authenticator = webroot

[[webroot]]
example.com = /var/www/html
EOF

out=$(_cb_read_certbot_renewal "webroot-basic")
rc=$?
assert_exit_code 0 "$rc" "T1: webroot-basic return code"
line1=$(echo "$out" | sed -n '1p')
line2=$(echo "$out" | sed -n '2p')
assert_eq "webroot" "$line1" "T1: authenticator=webroot"
assert_eq "/var/www/html" "$line2" "T1: webroot_path=/var/www/html"

# Test 2: webroot with webroot_path key (alternative format with comma)
cat > "$_RENEWAL_DIR/webroot-path-key.conf" <<'EOF'
[renewalparams]
authenticator = webroot
webroot_path = /var/www/letsencrypt,
EOF

out=$(_cb_read_certbot_renewal "webroot-path-key")
rc=$?
assert_exit_code 0 "$rc" "T2: webroot_path-key return code"
line1=$(echo "$out" | sed -n '1p')
line2=$(echo "$out" | sed -n '2p')
assert_eq "webroot" "$line1" "T2: authenticator=webroot"
assert_eq "/var/www/letsencrypt" "$line2" "T2: webroot_path without comma"

# Test 3: nginx authenticator (no webroot)
cat > "$_RENEWAL_DIR/nginx-auth.conf" <<'EOF'
[renewalparams]
authenticator = nginx
EOF

out=$(_cb_read_certbot_renewal "nginx-auth")
rc=$?
assert_exit_code 0 "$rc" "T3: nginx-auth return code"
line1=$(echo "$out" | sed -n '1p')
line2=$(echo "$out" | sed -n '2p')
assert_eq "nginx" "$line1" "T3: authenticator=nginx"
assert_eq "" "$line2" "T3: no webroot_path"

# Test 4: standalone authenticator
cat > "$_RENEWAL_DIR/standalone-auth.conf" <<'EOF'
[renewalparams]
authenticator = standalone
EOF

out=$(_cb_read_certbot_renewal "standalone-auth")
rc=$?
assert_exit_code 0 "$rc" "T4: standalone return code"
line1=$(echo "$out" | sed -n '1p')
line2=$(echo "$out" | sed -n '2p')
assert_eq "standalone" "$line1" "T4: authenticator=standalone"
assert_eq "" "$line2" "T4: standalone has no webroot_path"

# Test 5: non-existent file -> return code 1
_cb_read_certbot_renewal "nonexistent-domain" >/dev/null 2>&1
rc=$?
assert_exit_code 1 "$rc" "T5: missing file -> rc=1"

# Test 6: empty file -> return code 1
touch "$_RENEWAL_DIR/empty.conf"
_cb_read_certbot_renewal "empty" >/dev/null 2>&1
rc=$?
assert_exit_code 1 "$rc" "T6: empty file -> rc=1"

# Test 7: webroot with spaces around = in [[webroot]] section
cat > "$_RENEWAL_DIR/webroot-spaces.conf" <<'EOF'
[renewalparams]
authenticator = webroot

[[webroot]]
example.com =    /opt/acme/webroot
EOF

out=$(_cb_read_certbot_renewal "webroot-spaces")
rc=$?
assert_exit_code 0 "$rc" "T7: webroot-spaces return code"
line1=$(echo "$out" | sed -n '1p')
line2=$(echo "$out" | sed -n '2p')
assert_eq "webroot" "$line1" "T7: authenticator=webroot"
assert_eq "/opt/acme/webroot" "$line2" "T7: path stripped of spaces"

# Test 8: multiple domains in [[webroot]] section -> returns first path
cat > "$_RENEWAL_DIR/webroot-multi.conf" <<'EOF'
[renewalparams]
authenticator = webroot

[[webroot]]
example.com = /var/www/html
www.example.com = /var/www/html
EOF

out=$(_cb_read_certbot_renewal "webroot-multi")
rc=$?
assert_exit_code 0 "$rc" "T8: webroot-multi return code"
line2=$(echo "$out" | sed -n '2p')
assert_eq "/var/www/html" "$line2" "T8: returns first path from multiple domains"

# Test 9: authenticator with extra spaces around equals sign
cat > "$_RENEWAL_DIR/auth-spaces.conf" <<'EOF'
[renewalparams]
authenticator   =   webroot

[[webroot]]
d.cz = /srv/acme
EOF

out=$(_cb_read_certbot_renewal "auth-spaces")
line1=$(echo "$out" | sed -n '1p')
assert_eq "webroot" "$line1" "T9: authenticator with extra spaces parsed correctly"

# Test 10: [[webroot]] section terminated by another [section]
# Verifies that awk correctly stops reading after the next [ block.
cat > "$_RENEWAL_DIR/webroot-section-end.conf" <<'EOF'
[renewalparams]
authenticator = webroot

[[webroot]]
test.cz = /var/www/test

[http-01]
port = 80
EOF

out=$(_cb_read_certbot_renewal "webroot-section-end")
line2=$(echo "$out" | sed -n '2p')
assert_eq "/var/www/test" "$line2" "T10: [[webroot]] terminated by new section"

# Test 11: webroot_path fallback - [[webroot]] section missing entirely
cat > "$_RENEWAL_DIR/webroot-fallback.conf" <<'EOF'
[renewalparams]
authenticator = webroot
webroot_path = /var/www/fallback
EOF

out=$(_cb_read_certbot_renewal "webroot-fallback")
line2=$(echo "$out" | sed -n '2p')
assert_eq "/var/www/fallback" "$line2" "T11: fallback to webroot_path when [[webroot]] is missing"

# ============================================================================
# Tests for _cb_tomcat_restore_root_context
# ============================================================================
t_info "=== _cb_tomcat_restore_root_context ==="

# Test 12: ROOT.xml does not exist -> noop, rc=0
_reset_tomcat_sandbox
_cb_tomcat_restore_root_context
rc=$?
assert_exit_code 0 "$rc" "T12: missing ROOT.xml -> noop (rc=0)"

# Test 13: ROOT.xml with certberus marker + backup exists -> restores from backup
_reset_tomcat_sandbox
local_ctx="$TOMCAT_CONF_DIR/Catalina/localhost"
echo '<Context docBase="/var/www/acme" <!-- certberus --> />' > "$local_ctx/ROOT.xml"
echo '<Context docBase="/usr/share/tomcat/webapps/ROOT" />' > "$local_ctx/ROOT.xml.certberus-bak"
_CB_TOMCAT_ORIG_ROOT_XML="$local_ctx/ROOT.xml.certberus-bak"

_cb_tomcat_restore_root_context
rc=$?
assert_exit_code 0 "$rc" "T13: certberus marker + backup -> rc=0"
assert_file_exists "$local_ctx/ROOT.xml" "T13: ROOT.xml exists after restore"
content=$(cat "$local_ctx/ROOT.xml")
assert_contains "$content" "/usr/share/tomcat/webapps/ROOT" "T13: ROOT.xml restored from backup"
assert_not_contains "$content" "certberus" "T13: ROOT.xml does not contain certberus marker"

# Test 14: ROOT.xml with certberus marker + no backup -> delete ROOT.xml
_reset_tomcat_sandbox
local_ctx="$TOMCAT_CONF_DIR/Catalina/localhost"
echo '<Context docBase="/var/www/acme" <!-- certberus --> />' > "$local_ctx/ROOT.xml"
# _CB_TOMCAT_ORIG_ROOT_XML is empty (reset)

_cb_tomcat_restore_root_context
rc=$?
assert_exit_code 0 "$rc" "T14: certberus marker without backup -> rc=0"
if [[ ! -f "$local_ctx/ROOT.xml" ]]; then
    t_pass "T14: ROOT.xml deleted (no backup)"
else
    t_fail "T14: ROOT.xml should have been deleted"
fi

# Test 15: ROOT.xml with docBase="/var/www/acme" (without certberus word) + backup -> restores
_reset_tomcat_sandbox
local_ctx="$TOMCAT_CONF_DIR/Catalina/localhost"
echo '<Context docBase="/var/www/acme" />' > "$local_ctx/ROOT.xml"
echo '<Context docBase="/opt/app/ROOT" />' > "$local_ctx/ROOT.xml.orig"
_CB_TOMCAT_ORIG_ROOT_XML="$local_ctx/ROOT.xml.orig"

_cb_tomcat_restore_root_context
content=$(cat "$local_ctx/ROOT.xml")
assert_contains "$content" "/opt/app/ROOT" "T15: docBase acme + backup -> restored"

# Test 16: ROOT.xml WITHOUT certberus/acme markers -> leave unchanged
_reset_tomcat_sandbox
local_ctx="$TOMCAT_CONF_DIR/Catalina/localhost"
echo '<Context docBase="/usr/share/app/ROOT" />' > "$local_ctx/ROOT.xml"
original_content=$(cat "$local_ctx/ROOT.xml")

_cb_tomcat_restore_root_context
rc=$?
after_content=$(cat "$local_ctx/ROOT.xml")
assert_eq "$original_content" "$after_content" "T16: foreign ROOT.xml left unchanged"

# Test 17: ROOT.xml with certberus marker + _CB_TOMCAT_ORIG_ROOT_XML set, but file missing -> delete
_reset_tomcat_sandbox
local_ctx="$TOMCAT_CONF_DIR/Catalina/localhost"
echo '<Context docBase="/var/www/acme" <!-- certberus --> />' > "$local_ctx/ROOT.xml"
_CB_TOMCAT_ORIG_ROOT_XML="$local_ctx/nonexistent-backup.xml"

_cb_tomcat_restore_root_context
if [[ ! -f "$local_ctx/ROOT.xml" ]]; then
    t_pass "T17: backup does not exist -> ROOT.xml deleted (fallback)"
else
    t_fail "T17: ROOT.xml should have been deleted when backup is missing"
fi

# Test 18: ROOT.xml with docBase="/var/www/acme" + no backup -> delete
_reset_tomcat_sandbox
local_ctx="$TOMCAT_CONF_DIR/Catalina/localhost"
echo '<Context docBase="/var/www/acme" />' > "$local_ctx/ROOT.xml"
_CB_TOMCAT_ORIG_ROOT_XML=""

_cb_tomcat_restore_root_context
if [[ ! -f "$local_ctx/ROOT.xml" ]]; then
    t_pass "T18: acme docBase without backup -> ROOT.xml deleted"
else
    t_fail "T18: ROOT.xml should have been deleted"
fi

# Test 19: empty TOMCAT_CONF_DIR/Catalina/localhost (directory does not exist) -> noop
_reset_tomcat_sandbox
rm -rf "$TOMCAT_CONF_DIR/Catalina"
_cb_tomcat_restore_root_context
rc=$?
assert_exit_code 0 "$rc" "T19: missing Catalina/ directory -> noop"

# Test 20: ROOT.xml with both markers (certberus and acme docBase)
_reset_tomcat_sandbox
local_ctx="$TOMCAT_CONF_DIR/Catalina/localhost"
echo '<Context docBase="/var/www/acme" <!-- certberus managed --> />' > "$local_ctx/ROOT.xml"
_CB_TOMCAT_ORIG_ROOT_XML=""

_cb_tomcat_restore_root_context
if [[ ! -f "$local_ctx/ROOT.xml" ]]; then
    t_pass "T20: both markers without backup -> deleted"
else
    t_fail "T20: ROOT.xml should have been deleted"
fi

t_summary
