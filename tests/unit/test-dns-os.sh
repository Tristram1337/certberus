#!/bin/bash
# tests/unit/test-dns-os.sh
# Offline unit tests for lib/dns.sh and lib/os.sh.
# Tests DNS resolution (with mocks), CAA checks, OS detection, package manager.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/assert.sh"
source "$HERE/../lib/env.sh"

SANDBOX=$(t_mktempdir)
t_isolate_cb_dirs "$SANDBOX"
t_stub_log_helpers

# Mock directory - all external commands will be mocked here
MOCK="$SANDBOX/mock-bin"
mkdir -p "$MOCK"

# Save original PATH for restoration before OS tests
ORIG_PATH="$PATH"

# Note: t_cleanup cleans _CB_TEST_TMPDIRS, but SANDBOX=$(t_mktempdir) runs
# in a subshell, so the array stays empty. We clean manually.
trap 'rm -rf "$SANDBOX" 2>/dev/null; true' EXIT

# ============================================================
# Sourcing lib/dns.sh and lib/os.sh
# dns.sh does not need other libs, but calls cb_warn from common.sh
# (we already have a stub from t_stub_log_helpers)
# ============================================================

# Load dns.sh
# shellcheck disable=SC1091
source "$CB_REPO_ROOT/lib/dns.sh"

# os.sh calls cb_detect_os() on source - that is OK
# shellcheck disable=SC1091
source "$CB_REPO_ROOT/lib/os.sh"

# ============================================================
# 1. cb_local_ipv4_list - actual local IPv4 addresses
# ============================================================
echo "=== 1. cb_local_ipv4_list ==="

OUT=$(cb_local_ipv4_list)
# Must return at least one IP on a Debian machine
if [[ -z "$OUT" ]]; then
    t_fail "cb_local_ipv4_list: empty output"
else
    t_pass "cb_local_ipv4_list: returns non-empty output"
fi

# Every IP must be a valid dotted-quad
_all_valid=1
for ip in $OUT; do
    if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        _all_valid=0
        t_fail "cb_local_ipv4_list: invalid IP format '$ip'"
        break
    fi
done
(( _all_valid )) && t_pass "cb_local_ipv4_list: all IPs have valid dotted-quad format"

# ============================================================
# 2. cb_local_ipv6_list - may be empty on some machines
# ============================================================
echo "=== 2. cb_local_ipv6_list ==="

OUT6=$(cb_local_ipv6_list)
if [[ -z "$OUT6" ]]; then
    t_skip "cb_local_ipv6_list: no global IPv6 addresses (expected on some machines)"
else
    t_pass "cb_local_ipv6_list: returns non-empty output"
    # Every IPv6 must contain ':'
    _all_v6=1
    for ip6 in $OUT6; do
        if [[ "$ip6" != *:* ]]; then
            _all_v6=0
            t_fail "cb_local_ipv6_list: IP '$ip6' does not contain ':'"
            break
        fi
    done
    (( _all_v6 )) && t_pass "cb_local_ipv6_list: all IPv6 contain ':'"
fi

# ============================================================
# 3. cb_server_ipv4 - mock curl, test cache
# ============================================================
echo "=== 3. cb_server_ipv4 ==="

# Reset cache
unset CB_SERVER_IP4 2>/dev/null || true
CB_SERVER_IP4=""

# Mock curl
cat > "$MOCK/curl" <<'EOF'
#!/bin/bash
echo "1.2.3.4"
EOF
chmod +x "$MOCK/curl"
t_prepend_mock_path "$MOCK"

# Call cb_server_ipv4 with mocked curl
GOT=$(CB_SERVER_IP4="" cb_server_ipv4)
assert_eq "1.2.3.4" "$GOT" "cb_server_ipv4: returns mocked IP 1.2.3.4"

# Test cache: set CB_SERVER_IP4 directly -> must not call curl
GOT_CACHED=$(CB_SERVER_IP4="9.8.7.6" cb_server_ipv4)
assert_eq "9.8.7.6" "$GOT_CACHED" "cb_server_ipv4: cache hit (returns cached 9.8.7.6)"

# ============================================================
# 4. cb_server_ipv6 - mock curl, test cache
# ============================================================
echo "=== 4. cb_server_ipv6 ==="

# Mock curl for IPv6
cat > "$MOCK/curl" <<'EOF'
#!/bin/bash
echo "2001:db8::1"
EOF
chmod +x "$MOCK/curl"

GOT6=$(CB_SERVER_IP6="" cb_server_ipv6)
assert_eq "2001:db8::1" "$GOT6" "cb_server_ipv6: returns mocked IPv6"

# Test cache
GOT6_CACHED=$(CB_SERVER_IP6="fe80::cafe" cb_server_ipv6)
assert_eq "fe80::cafe" "$GOT6_CACHED" "cb_server_ipv6: cache hit"

# ============================================================
# 5. cb_resolve_a - mock dig, fallback to host
# ============================================================
echo "=== 5. cb_resolve_a ==="

# Mock dig
cat > "$MOCK/dig" <<'EOF'
#!/bin/bash
echo "1.2.3.4"
echo "5.6.7.8"
EOF
chmod +x "$MOCK/dig"

GOT_A=$(cb_resolve_a "example.com")
assert_contains "$GOT_A" "1.2.3.4" "cb_resolve_a: contains first IP"
assert_contains "$GOT_A" "5.6.7.8" "cb_resolve_a: contains second IP"

# Fallback to host when dig is not in PATH
# Remove mock dig and add mock host
rm -f "$MOCK/dig"
cat > "$MOCK/host" <<'EOF'
#!/bin/bash
echo "example.com has address 10.20.30.40"
echo "example.com has address 50.60.70.80"
EOF
chmod +x "$MOCK/host"

# We must ensure the system dig is not available - replace it with nonexistent
cat > "$MOCK/dig" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$MOCK/dig"
# Better to completely remove dig from mock and hide the system dig
rm -f "$MOCK/dig"

# We must reset dns.sh cache - re-source is not needed, functions use command -v
# But: 'command -v dig' finds system dig. So we must hide PATH.
# We do this by setting PATH to only mock + minimal system paths
SAVE_PATH="$PATH"
export PATH="$MOCK:/usr/bin:/bin"

# Verify dig is not available (only in /usr/bin|/bin if system dig exists)
if ! command -v dig >/dev/null 2>&1; then
    GOT_HOST=$(cb_resolve_a "example.com")
    assert_contains "$GOT_HOST" "10.20.30.40" "cb_resolve_a: host fallback - first IP"
    assert_contains "$GOT_HOST" "50.60.70.80" "cb_resolve_a: host fallback - second IP"
else
    # dig is in /usr/bin - we must shadow it with an invalid script
    cat > "$MOCK/dig" <<'EOF'
#!/bin/bash
# Intentionally fail so host fallback kicks in
exit 127
EOF
    chmod +x "$MOCK/dig"
    # dig fails, but 'command -v dig' still finds it...
    # Use a different approach: mock dig to return nothing valid
    cat > "$MOCK/dig" <<'EOF'
#!/bin/bash
# Return empty output - simulates nonexistent domain
exit 0
EOF
    chmod +x "$MOCK/dig"
    # cb_resolve_a uses dig as first option (command -v dig), so it is not easy
    # to test fallback when dig exists. Skipping.
    t_skip "cb_resolve_a: host fallback - dig is in system PATH, cannot easily shadow"
fi
export PATH="$SAVE_PATH"

# ============================================================
# 6. cb_resolve_aaaa - mock dig with IPv6 address
# ============================================================
echo "=== 6. cb_resolve_aaaa ==="

cat > "$MOCK/dig" <<'EOF'
#!/bin/bash
echo "2001:db8::100"
echo "2001:db8::200"
EOF
chmod +x "$MOCK/dig"

GOT_AAAA=$(cb_resolve_aaaa "example.com")
assert_contains "$GOT_AAAA" "2001:db8::100" "cb_resolve_aaaa: contains first IPv6"
assert_contains "$GOT_AAAA" "2001:db8::200" "cb_resolve_aaaa: contains second IPv6"

# ============================================================
# 7. cb_domain_points_here - complex mock of all dependencies
# ============================================================
echo "=== 7. cb_domain_points_here ==="

# Set server IP via cache
export CB_SERVER_IP4="10.0.0.1"
export CB_SERVER_IP6=""

# Mock cb_local_ipv4_list - override funkce primo
cb_local_ipv4_list() { printf '%s' "10.0.0.1 192.168.1.1 "; }
cb_local_ipv6_list() { printf '%s' ""; }

# Mock dig: returns IP based on domain
cat > "$MOCK/dig" <<'DIGEOF'
#!/bin/bash
# Parse domain from arguments
domain=""
rtype=""
for arg in "$@"; do
    case "$arg" in
        +*) continue ;;
        A|AAAA|CAA) rtype="$arg" ;;
        *.*) domain="$arg" ;;
    esac
done

case "$rtype" in
    A)
        case "$domain" in
            match.example.com)   echo "10.0.0.1" ;;
            nomatch.example.com) echo "99.99.99.99" ;;
            multi.example.com)   echo "99.99.99.99"; echo "192.168.1.1" ;;
        esac
        ;;
    AAAA)
        # No AAAA records for tests
        ;;
esac
DIGEOF
chmod +x "$MOCK/dig"

# Test: domain points to us (10.0.0.1 is in our set)
cb_domain_points_here "match.example.com"
assert_eq "0" "$?" "cb_domain_points_here: match.example.com -> success (IP matches)"

# Test: domain does not point to us
cb_domain_points_here "nomatch.example.com"
rc=$?
assert_eq "1" "$rc" "cb_domain_points_here: nomatch.example.com -> fail (IP does not match)"

# Test: multi-IP where one of them is our local
cb_domain_points_here "multi.example.com"
assert_eq "0" "$?" "cb_domain_points_here: multi.example.com -> success (second IP is local)"

# Test: domain without DNS records (dig returns nothing) -> fail
cb_domain_points_here "neexistuje.example.com"
rc=$?
assert_eq "1" "$rc" "cb_domain_points_here: neexistuje.example.com -> fail (no DNS records)"

# Test: CB_SKIP_DNS_CHECK=1 -> always returns 0
CB_SKIP_DNS_CHECK=1 cb_domain_points_here "nomatch.example.com"
assert_eq "0" "$?" "cb_domain_points_here: CB_SKIP_DNS_CHECK=1 -> always success"

# ============================================================
# 8. cb_check_caa - CAA records
# ============================================================
echo "=== 8. cb_check_caa ==="

# Mock dig for CAA queries
cat > "$MOCK/dig" <<'DIGEOF'
#!/bin/bash
domain=""
rtype=""
for arg in "$@"; do
    case "$arg" in
        +*) continue ;;
        A|AAAA|CAA) rtype="$arg" ;;
        *.*) domain="$arg" ;;
    esac
done

case "$rtype" in
    CAA)
        case "$domain" in
            nocaa.example.com)
                # No CAA records
                ;;
            lecaa.example.com)
                echo '0 issue "letsencrypt.org"'
                ;;
            haricacaa.example.com)
                echo '0 issue "sectigo.com"'
                ;;
            paramcaa.example.com)
                echo '0 issue "letsencrypt.org;validationmethods=http-01"'
                ;;
            multicaa.example.com)
                echo '0 issue "digicert.com"'
                echo '0 issue "letsencrypt.org"'
                ;;
            wildcaa.example.com)
                echo '0 issuewild "letsencrypt.org"'
                ;;
            # For walk-up tests: sub.walkcaa.example.com has no CAA, walkcaa.example.com does
            walkcaa.example.com)
                echo '0 issue "letsencrypt.org"'
                ;;
            # example.com - for walk-up from nocaa-sub.example.com
            example.com)
                # empty - simulates that even the apex has no CAA
                ;;
        esac
        ;;
esac
DIGEOF
chmod +x "$MOCK/dig"

# 8a: No CAA records -> allowed (returns 0)
cb_check_caa "nocaa.example.com" "letsencrypt.org"
assert_eq "0" "$?" "cb_check_caa: no CAA records -> allowed"

# 8b: CAA with matching issuer -> allowed
cb_check_caa "lecaa.example.com" "letsencrypt.org"
assert_eq "0" "$?" "cb_check_caa: CAA issue letsencrypt.org -> allowed"

# 8c: CAA with non-matching issuer -> denied
cb_check_caa "haricacaa.example.com" "letsencrypt.org"
rc=$?
assert_eq "1" "$rc" "cb_check_caa: CAA issue sectigo.com != letsencrypt.org -> denied"

# 8d: CAA with parameters (validationmethods) -> allowed
cb_check_caa "paramcaa.example.com" "letsencrypt.org"
assert_eq "0" "$?" "cb_check_caa: CAA with parameters letsencrypt.org;validation... -> allowed"

# 8e: Multi-CAA where at least one matches -> allowed
cb_check_caa "multicaa.example.com" "letsencrypt.org"
assert_eq "0" "$?" "cb_check_caa: multi-CAA with one match -> allowed"

# 8f: Walk-up - sub.walkcaa.example.com has no CAA, walkcaa.example.com has
cb_check_caa "sub.walkcaa.example.com" "letsencrypt.org"
assert_eq "0" "$?" "cb_check_caa: walk-up finds CAA on parent zone -> allowed"

# 8g: dig not available -> skip check (returns 0)
# Hide dig temporarily
SAVE_PATH="$PATH"
# Replace dig with a nonexistent command
cat > "$MOCK/dig" <<'EOF'
#!/bin/bash
# Intentionally not a valid dig
exit 127
EOF
chmod +x "$MOCK/dig"
# To make 'command -v dig' fail, we must hide dig completely
rm -f "$MOCK/dig"
# If the system dig exists, we cannot easily hide it.
# We use a subshell with a restricted PATH
GOT_NO_DIG=$(
    export PATH="$MOCK:/usr/lib:/usr/libexec"
    if command -v dig >/dev/null 2>&1; then
        echo "dig-found"
    else
        cb_check_caa "haricacaa.example.com" "letsencrypt.org"
        echo "$?"
    fi
)
if [[ "$GOT_NO_DIG" == "dig-found" ]]; then
    t_skip "cb_check_caa: dig not available test - dig is in system PATH"
else
    assert_eq "0" "$GOT_NO_DIG" "cb_check_caa: dig not available -> skip (returns 0)"
fi
export PATH="$SAVE_PATH"

# Restore mock dig for further tests
cat > "$MOCK/dig" <<'EOF'
#!/bin/bash
echo ""
EOF
chmod +x "$MOCK/dig"

# 8h: CAA with non-matching issuer for HARICA
cat > "$MOCK/dig" <<'DIGEOF'
#!/bin/bash
domain=""
rtype=""
for arg in "$@"; do
    case "$arg" in
        +*) continue ;;
        CAA) rtype="$arg" ;;
        *.*) domain="$arg" ;;
    esac
done
if [[ "$rtype" == "CAA" ]]; then
    echo '0 issue "letsencrypt.org"'
fi
DIGEOF
chmod +x "$MOCK/dig"

cb_check_caa "any.example.com" "sectigo.com"
rc=$?
assert_eq "1" "$rc" "cb_check_caa: CAA issue letsencrypt.org != sectigo.com -> denied"

# ============================================================
# 9. cb_detect_os - on a Debian machine
# ============================================================
echo "=== 9. cb_detect_os ==="

# Restore original PATH for OS tests (we need real system tools)
export PATH="$ORIG_PATH"

# Re-detect (already called on source, but just to be safe)
cb_detect_os

assert_eq "debian" "$CB_OS_ID" "cb_detect_os: CB_OS_ID == debian"

assert_ne "" "$CB_OS_VERSION" "cb_detect_os: CB_OS_VERSION is not empty"

assert_eq "apt" "$CB_PKG_MGR" "cb_detect_os: CB_PKG_MGR == apt (Debian)"

# CB_PKG_UPDATE must contain apt-get
assert_contains "$CB_PKG_UPDATE" "apt-get" "cb_detect_os: CB_PKG_UPDATE contains apt-get"

# CB_PKG_INSTALL must contain apt-get install
assert_contains "$CB_PKG_INSTALL" "apt-get install" "cb_detect_os: CB_PKG_INSTALL contains apt-get install"

# CB_PKG_INSTALL contains DEBIAN_FRONTEND=noninteractive
assert_contains "$CB_PKG_INSTALL" "DEBIAN_FRONTEND=noninteractive" \
    "cb_detect_os: CB_PKG_INSTALL has DEBIAN_FRONTEND=noninteractive"

# ============================================================
# 10. cb_require_os - allowed vs. disallowed OS
# ============================================================
echo "=== 10. cb_require_os ==="

# 10a: cb_require_os "debian" -> success (we are on debian)
cb_require_os "debian"
assert_eq "0" "$?" "cb_require_os: debian -> success"

# 10b: cb_require_os "rhel" -> fails (caught in subshell, cb_die returns 99)
OUT_RHEL=$(cb_require_os "rhel" 2>&1 || true)
RC_RHEL=${PIPESTATUS[0]:-$?}
# cb_die returns exit 99 (per t_stub_log_helpers)
# In subshell caught via ||true, but we want to verify DIE message
if echo "$OUT_RHEL" | grep -q "DIE"; then
    t_pass "cb_require_os: rhel -> die with error message"
else
    # Alternative: try subshell with explicit exit code catching
    set +e
    MSG=$(cb_require_os "rhel" 2>&1)
    RHEL_RC=$?
    set -e
    if (( RHEL_RC != 0 )); then
        t_pass "cb_require_os: rhel -> non-zero exit ($RHEL_RC)"
    else
        t_fail "cb_require_os: rhel should have failed"
    fi
fi

# 10c: cb_require_os "rhel" "debian" -> success (debian is in the list)
cb_require_os "rhel" "debian"
assert_eq "0" "$?" "cb_require_os: rhel+debian -> success (debian in list)"

# 10d: cb_require_os with multiple unsupported -> fails
set +e
MSG=$(cb_require_os "alpine" "fedora" 2>&1)
RC_MULTI=$?
set -e
if (( RC_MULTI != 0 )); then
    t_pass "cb_require_os: alpine+fedora -> fails (neither is our OS)"
else
    t_fail "cb_require_os: alpine+fedora should have failed"
fi

# ============================================================
# 11. cb_pkg_installed - test with real and nonexistent package
# ============================================================
echo "=== 11. cb_pkg_installed ==="

# 11a: bash is certainly installed
if cb_pkg_installed "bash"; then
    t_pass "cb_pkg_installed: bash is installed"
else
    t_fail "cb_pkg_installed: bash should be installed"
fi

# 11b: nonexistent package
if cb_pkg_installed "nonexistent-pkg-xyz-123456"; then
    t_fail "cb_pkg_installed: nonexistent-pkg should not be installed"
else
    t_pass "cb_pkg_installed: nonexistent-pkg is not installed"
fi

# 11c: coreutils should also be installed
if cb_pkg_installed "coreutils"; then
    t_pass "cb_pkg_installed: coreutils is installed"
else
    t_skip "cb_pkg_installed: coreutils is not installed (not a package on this system?)"
fi

# ============================================================
# 12. cb_pkg_install s DRY_RUN
# ============================================================
echo "=== 12. cb_pkg_install (DRY_RUN) ==="

# 12a: DRY_RUN=1 -> does not install, returns 0
CB_DRY_RUN=1
cb_pkg_install "fake-package-xyz" 2>/dev/null
assert_eq "0" "$?" "cb_pkg_install: DRY_RUN=1 -> returns 0 without installing"

# 12b: Verify the package is really not installed (dry run did nothing)
if cb_pkg_installed "fake-package-xyz"; then
    t_fail "cb_pkg_install DRY_RUN: fake-package should not be installed"
else
    t_pass "cb_pkg_install DRY_RUN: package was not actually installed"
fi
unset CB_DRY_RUN

# 12c: Empty CB_PKG_MGR -> error
SAVE_PKG="$CB_PKG_MGR"
CB_PKG_MGR=""
CB_DRY_RUN=0
set +e
cb_pkg_install "some-package" 2>/dev/null
RC_NOPKG=$?
set -e
assert_eq "1" "$RC_NOPKG" "cb_pkg_install: empty CB_PKG_MGR -> error (rc=1)"
CB_PKG_MGR="$SAVE_PKG"

# ============================================================
# Additional tests - edge cases
# ============================================================
echo "=== Additional tests ==="

# Mock curl for further tests
export PATH="$MOCK:$ORIG_PATH"
cat > "$MOCK/curl" <<'EOF'
#!/bin/bash
echo "  1.2.3.4  "
EOF
chmod +x "$MOCK/curl"

# cb_server_ipv4 with whitespace around IP (curl may return newlines)
GOT_WS=$(CB_SERVER_IP4="" cb_server_ipv4)
assert_eq "1.2.3.4" "$GOT_WS" "cb_server_ipv4: trims whitespace from curl output"

# cb_server_ipv6 with empty curl output -> fallback to local
cat > "$MOCK/curl" <<'EOF'
#!/bin/bash
echo ""
EOF
chmod +x "$MOCK/curl"

# cb_server_ipv6 with empty curl and empty cb_local_ipv6_list -> empty
cb_local_ipv6_list() { printf '%s' ""; }
GOT_EMPTY6=$(CB_SERVER_IP6="" cb_server_ipv6)
assert_eq "" "$GOT_EMPTY6" "cb_server_ipv6: empty curl + empty local -> empty output"

# cb_server_ipv6 with empty curl but non-empty cb_local_ipv6_list -> fallback
cb_local_ipv6_list() { printf '%s' "2001:db8::ff "; }
GOT_FB6=$(CB_SERVER_IP6="" cb_server_ipv6)
assert_eq "2001:db8::ff" "$GOT_FB6" "cb_server_ipv6: empty curl -> fallback to local IPv6"

# Restore original cb_local_ipv6_list
# Reset _CB_DNS_LOADED and re-source dns.sh
unset _CB_DNS_LOADED
export PATH="$ORIG_PATH"
# shellcheck disable=SC1091
source "$CB_REPO_ROOT/lib/dns.sh"

# cb_resolve_a with empty dig output (nonexistent domain)
export PATH="$MOCK:$ORIG_PATH"
cat > "$MOCK/dig" <<'EOF'
#!/bin/bash
# Nonexistent domain - empty output
exit 0
EOF
chmod +x "$MOCK/dig"

GOT_EMPTY_A=$(cb_resolve_a "nonexistent.example.com")
# Must be empty (or just whitespace)
GOT_EMPTY_A_TRIMMED=$(echo "$GOT_EMPTY_A" | tr -d '[:space:]')
assert_eq "" "$GOT_EMPTY_A_TRIMMED" "cb_resolve_a: nonexistent domain -> empty output"

# cb_resolve_aaaa with empty dig
GOT_EMPTY_AAAA=$(cb_resolve_aaaa "nonexistent.example.com")
GOT_EMPTY_AAAA_TRIMMED=$(echo "$GOT_EMPTY_AAAA" | tr -d '[:space:]')
assert_eq "" "$GOT_EMPTY_AAAA_TRIMMED" "cb_resolve_aaaa: nonexistent domain -> empty output"

# cb_detect_os: CB_OS_CODENAME is not empty on Debian
export PATH="$ORIG_PATH"
cb_detect_os
assert_ne "" "${CB_OS_CODENAME:-}" "cb_detect_os: CB_OS_CODENAME is not empty on Debian"

# cb_require_os via ID_LIKE: debian is in ID_LIKE -> 'ubuntu' scenario
# On our Debian we test that ID_LIKE match works
# If CB_OS_LIKE contains something, we test it
if [[ -n "${CB_OS_LIKE:-}" ]]; then
    # CB_OS_LIKE could be empty on pure Debian
    t_info "CB_OS_LIKE='$CB_OS_LIKE' - testing match"
    cb_require_os "$CB_OS_LIKE" 2>/dev/null
    assert_eq "0" "$?" "cb_require_os: match via CB_OS_LIKE"
else
    t_skip "cb_require_os ID_LIKE match: CB_OS_LIKE is empty on this system"
fi

# ============================================================
# Summary
# ============================================================
t_summary
