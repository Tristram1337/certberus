#!/bin/bash
# tests/unit/test-common.sh
# Comprehensive unit tests for lib/common.sh.
# Covers: validation, config, retry, snapshot/rollback, require, install marker, svc.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/assert.sh"
source "$HERE/../lib/env.sh"

SANDBOX="$(t_mktempdir common)" || exit 1
trap 't_cleanup' EXIT
t_isolate_cb_dirs "$SANDBOX"

# We need the real common.sh (not stubs) - reset guard and load it
unset _CB_COMMON_LOADED
export CB_DRY_RUN=0
export CB_VERBOSE=0
export CB_ASSUME_YES=1
export CB_AUTO_ROLLBACK=0
# shellcheck disable=SC1091
source "$CB_REPO_ROOT/lib/common.sh"

# ============================================================================
# 1. cb_validate_domain
# ============================================================================
t_info "--- cb_validate_domain ---"

# Valid domains
cb_validate_domain "example.com"
assert_eq 0 $? "domain: example.com is valid"

cb_validate_domain "sub.example.com"
assert_eq 0 $? "domain: sub.example.com is valid"

cb_validate_domain "a-b.example.com"
assert_eq 0 $? "domain: a-b.example.com is valid"

cb_validate_domain "foo.bar.baz.co.uk"
assert_eq 0 $? "domain: foo.bar.baz.co.uk is valid"

cb_validate_domain "a.b.cc"
assert_eq 0 $? "domain: a.b.cc (single-char labels) is valid"

# Invalid domains
cb_validate_domain ""
assert_eq 1 $? "domain: empty string is invalid"

cb_validate_domain "com"
assert_eq 1 $? "domain: bare 'com' is invalid"

cb_validate_domain "-starts-with-dash.com"
assert_eq 1 $? "domain: starts with dash is invalid"

cb_validate_domain "has space.com"
assert_eq 1 $? "domain: with space is invalid"

cb_validate_domain 'evil;rm.com'
assert_eq 1 $? "domain: with semicolon is invalid"

cb_validate_domain 'evil$(cmd).com'
assert_eq 1 $? "domain: with \$(cmd) is invalid"

cb_validate_domain 'evil`cmd`.com'
assert_eq 1 $? "domain: with backtick is invalid"

cb_validate_domain "1.2.3.4"
assert_eq 1 $? "domain: IP address 1.2.3.4 is invalid"

# Underscore - regex disallows it (labels [a-zA-Z0-9-]), but some DNS use it
# common.sh uses strict FQDN regex -> underscore fails
cb_validate_domain "underscore_domain.com"
assert_eq 1 $? "domain: underscore in label fails strict FQDN regex"

# Too-long label (64+ chars)
long_label=$(printf 'a%.0s' {1..64})
cb_validate_domain "${long_label}.example.com"
assert_eq 1 $? "domain: 64-char label is invalid (max 63)"

# Wildcard -> return code 2
cb_validate_domain "*.example.com"
assert_eq 2 $? "domain: wildcard *.example.com returns 2"

# ============================================================================
# 2. cb_validate_email
# ============================================================================
t_info "--- cb_validate_email ---"

cb_validate_email "user@example.com"
assert_eq 0 $? "email: user@example.com is valid"

cb_validate_email "user+tag@example.com"
assert_eq 0 $? "email: user+tag@example.com is valid"

cb_validate_email "a.b@c.de"
assert_eq 0 $? "email: a.b@c.de is valid"

cb_validate_email ""
assert_eq 1 $? "email: empty string is invalid"

cb_validate_email "no-at-sign"
assert_eq 1 $? "email: without @ is invalid"

cb_validate_email "@no-local.com"
assert_eq 1 $? "email: without local part is invalid"

cb_validate_email "user@"
assert_eq 1 $? "email: without domain is invalid"

cb_validate_email "user@.com"
assert_eq 1 $? "email: user@.com is invalid"

cb_validate_email "user@com"
assert_eq 1 $? "email: user@com (no dot) is invalid"

# ============================================================================
# 3. cb_apply_cli_set
# ============================================================================
t_info "--- cb_apply_cli_set ---"

# Valid assignments
cb_apply_cli_set "CB_STAGING=1"
assert_eq "1" "$CB_STAGING" "cli_set: CB_STAGING=1 set correctly"

cb_apply_cli_set "CB_EMAIL=foo@bar.com"
assert_eq "foo@bar.com" "$CB_EMAIL" "cli_set: CB_EMAIL set"

cb_apply_cli_set "CB_ACME_URL=https://acme.example.com/dir"
assert_eq "https://acme.example.com/dir" "$CB_ACME_URL" "cli_set: CB_ACME_URL set"

# cb_apply_cli_set exports variables
(
    cb_apply_cli_set "CB_TESTEXPORT=hello"
    [[ "$(printenv CB_TESTEXPORT)" == "hello" ]]
) && t_pass "cli_set: variable is exported" \
  || t_fail "cli_set: variable is not exported"

# Invalid: non-CB_ prefix -> die (exit 99 from t_stub - but here we have real cb_die=exit 1)
out=$(cb_apply_cli_set "PATH=evil" 2>&1) ; rc=$?
assert_eq 1 $rc "cli_set: PATH=evil fails (non-CB_)"

# Invalid: shell characters in value
out=$(cb_apply_cli_set 'CB_BAD=$(evil)' 2>&1) ; rc=$?
assert_eq 1 $rc "cli_set: shell chars in value fail"

# Invalid: missing equals sign
out=$(cb_apply_cli_set "CB_NOEQ" 2>&1) ; rc=$?
assert_eq 1 $rc "cli_set: without equals sign fails"

# Invalid: spaces in value
out=$(cb_apply_cli_set "CB_BAD=has space" 2>&1) ; rc=$?
assert_eq 1 $rc "cli_set: space in value fails"

# ============================================================================
# 4. cb_sanitize_acme_url
# ============================================================================
t_info "--- cb_sanitize_acme_url ---"

# Placeholder URL with ".../" -> empty
CB_ACME_URL="https://acme.harica.gr/.../directory"
unset _CB_ACME_URL_WARNED
cb_sanitize_acme_url 2>/dev/null
assert_eq "" "$CB_ACME_URL" "sanitize: placeholder with .../ is discarded"

# Placeholder with VAS_UUID -> empty
CB_ACME_URL="https://acme.harica.gr/VAS_UUID/directory"
unset _CB_ACME_URL_WARNED
cb_sanitize_acme_url 2>/dev/null
assert_eq "" "$CB_ACME_URL" "sanitize: placeholder with VAS_UUID is discarded"

# Placeholder with YOUR_UUID -> empty
CB_ACME_URL="https://acme.harica.gr/YOUR_UUID/directory"
unset _CB_ACME_URL_WARNED
cb_sanitize_acme_url 2>/dev/null
assert_eq "" "$CB_ACME_URL" "sanitize: placeholder with YOUR_UUID is discarded"

# CA mismatch: LE + harica URL -> empty
CB_CA="letsencrypt"
CB_ACME_URL="https://acme.harica.gr/real-uuid/directory"
unset _CB_ACME_URL_WARNED
cb_sanitize_acme_url 2>/dev/null
assert_eq "" "$CB_ACME_URL" "sanitize: CA=letsencrypt + harica URL -> empty"

# CA mismatch: harica + LE URL -> empty
CB_CA="harica"
CB_ACME_URL="https://acme-v02.api.letsencrypt.org/directory"
unset _CB_ACME_URL_WARNED
cb_sanitize_acme_url 2>/dev/null
assert_eq "" "$CB_ACME_URL" "sanitize: CA=harica + LE URL -> empty"

# Correct match: LE + LE URL -> preserved
CB_CA="letsencrypt"
CB_ACME_URL="https://acme-v02.api.letsencrypt.org/directory"
unset _CB_ACME_URL_WARNED
cb_sanitize_acme_url 2>/dev/null
assert_eq "https://acme-v02.api.letsencrypt.org/directory" "$CB_ACME_URL" "sanitize: CA=letsencrypt + LE URL preserved"

# Correct match: harica + harica URL -> preserved
CB_CA="harica"
CB_ACME_URL="https://acme.harica.gr/real-uuid/directory"
unset _CB_ACME_URL_WARNED
cb_sanitize_acme_url 2>/dev/null
assert_eq "https://acme.harica.gr/real-uuid/directory" "$CB_ACME_URL" "sanitize: CA=harica + harica URL preserved"

# Empty URL -> stays empty (no error)
CB_ACME_URL=""
unset _CB_ACME_URL_WARNED
cb_sanitize_acme_url 2>/dev/null
assert_eq "" "$CB_ACME_URL" "sanitize: empty URL stays empty"

# ZeroSSL mismatch: zerossl CA + LE URL -> empty
CB_CA="zerossl"
CB_ACME_URL="https://acme-v02.api.letsencrypt.org/directory"
unset _CB_ACME_URL_WARNED
cb_sanitize_acme_url 2>/dev/null
assert_eq "" "$CB_ACME_URL" "sanitize: CA=zerossl + LE URL -> empty"

# ZeroSSL correct match
CB_CA="zerossl"
CB_ACME_URL="https://acme.zerossl.com/v2/DV90"
unset _CB_ACME_URL_WARNED
cb_sanitize_acme_url 2>/dev/null
assert_eq "https://acme.zerossl.com/v2/DV90" "$CB_ACME_URL" "sanitize: CA=zerossl + zerossl URL preserved"

# ============================================================================
# 5. cb_retry
# ============================================================================
t_info "--- cb_retry ---"

# Success on first attempt
cb_retry 3 0 true
assert_eq 0 $? "retry: true succeeds on first attempt"

# All attempts failed
cb_retry 3 0 false
assert_eq 1 $? "retry: false always fails -> non-zero"

# Success on second attempt (via counter file)
RETRY_COUNTER="$SANDBOX/retry_counter"
echo "0" > "$RETRY_COUNTER"
_test_retry_cmd() {
    local cnt
    cnt=$(cat "$RETRY_COUNTER")
    cnt=$((cnt + 1))
    echo "$cnt" > "$RETRY_COUNTER"
    (( cnt >= 2 ))  # success from 2nd attempt
}
cb_retry 3 0 _test_retry_cmd
assert_eq 0 $? "retry: success on 2nd attempt -> rc 0"
assert_eq "2" "$(cat "$RETRY_COUNTER")" "retry: command was called exactly 2 times"

# Single attempt, fails -> non-zero
cb_retry 1 0 false
assert_eq 1 $? "retry: single attempt, false -> non-zero"

# Zero attempts (tries=0) -> returns non-zero (command never runs)
# tries=0 while loop never executes -> rc stays 0 (init)
cb_retry 0 0 false
rc=$?
assert_eq 0 $rc "retry: tries=0 -> rc 0 (loop does not run)"

# ============================================================================
# 6. cb_snapshot + cb_snapshot_restore
# ============================================================================
t_info "--- cb_snapshot + cb_snapshot_restore ---"

# Create test directory with a file, snapshot, modify, restore
SNAP_DIR="$SANDBOX/snaptest"
mkdir -p "$SNAP_DIR"
echo "original-content" > "$SNAP_DIR/file.txt"
CB_LAST_SNAPSHOT=""

# cb_snapshot outputs cb_ok log + path to stdout, we use CB_LAST_SNAPSHOT
cb_snapshot "$SNAP_DIR" "unittest" >/dev/null 2>&1
assert_eq 0 $? "snapshot: creation successful"
assert_file_exists "$CB_LAST_SNAPSHOT" "snapshot: tar file exists"

# Modification
echo "modified-content" > "$SNAP_DIR/file.txt"
# Verify content is changed
assert_eq "modified-content" "$(cat "$SNAP_DIR/file.txt")" "snapshot: content changed before restore"

# Restore (tar -xzf ... -C / restores original absolute paths)
cb_snapshot_restore "$CB_LAST_SNAPSHOT" >/dev/null 2>&1
assert_eq 0 $? "snapshot_restore: successful restoration"
assert_eq "original-content" "$(cat "$SNAP_DIR/file.txt")" "snapshot_restore: original content restored"

# Snapshot of nonexistent source -> rc 1
out=$(cb_snapshot "/nonexistent/path/123456" "bad" 2>&1)
assert_eq 1 $? "snapshot: nonexistent source -> rc 1"

# DRY_RUN mode: snapshot does not create actual tar
CB_DRY_RUN=1
CB_LAST_SNAPSHOT=""
DRYDIR="$SANDBOX/drytest"
mkdir -p "$DRYDIR"
echo "dry" > "$DRYDIR/f.txt"
cb_snapshot "$DRYDIR" "dryrun" >/dev/null 2>&1
assert_eq 0 $? "snapshot dry-run: returns 0"
# In dry-run mode tar is not created (only log), but CB_LAST_SNAPSHOT is set
assert_ne "" "$CB_LAST_SNAPSHOT" "snapshot dry-run: CB_LAST_SNAPSHOT set"
[[ ! -f "$CB_LAST_SNAPSHOT" ]] \
    && t_pass "snapshot dry-run: tar file was not actually created" \
    || t_fail "snapshot dry-run: tar file was created (should not)"
CB_DRY_RUN=0

# ============================================================================
# 7. cb_auto_rollback
# ============================================================================
t_info "--- cb_auto_rollback ---"

# CB_AUTO_ROLLBACK=0 -> only hint, does not restore
ROLLDIR="$SANDBOX/rolltest"
mkdir -p "$ROLLDIR"
echo "orig" > "$ROLLDIR/data.txt"
CB_LAST_SNAPSHOT=""
cb_snapshot "$ROLLDIR" "rolltest" >/dev/null 2>&1
echo "broken" > "$ROLLDIR/data.txt"
CB_AUTO_ROLLBACK=0
cb_auto_rollback >/dev/null 2>&1
assert_eq "broken" "$(cat "$ROLLDIR/data.txt")" "auto_rollback: OFF -> does not restore (only hint)"

# CB_AUTO_ROLLBACK=1 + valid snapshot -> restores
CB_AUTO_ROLLBACK=1
cb_auto_rollback >/dev/null 2>&1
assert_eq "orig" "$(cat "$ROLLDIR/data.txt")" "auto_rollback: ON -> restores original content"

# CB_AUTO_ROLLBACK=1 + no snapshot -> rc 1
CB_AUTO_ROLLBACK=1
CB_LAST_SNAPSHOT=""
out=$(cb_auto_rollback 2>&1)
assert_eq 1 $? "auto_rollback: no snapshot -> rc 1"

# ============================================================================
# 8. cb_load_config
# ============================================================================
t_info "--- cb_load_config ---"

# Write test config.env
cat > "$CB_CONFIG_FILE" <<'CONFEOF'
CB_TEST_LOADED_VAR="hello_from_config"
CB_CA="letsencrypt"
CONFEOF

# Write advanced.env
cat > "$CB_ADVANCED_FILE" <<'ADVEOF'
CB_TEST_ADVANCED_VAR="advanced_value"
ADVEOF

# Reset CB_ACME_URL so sanitize has nothing to do
CB_ACME_URL=""
unset _CB_ACME_URL_WARNED 2>/dev/null || true

cb_load_config 2>/dev/null
assert_eq "hello_from_config" "${CB_TEST_LOADED_VAR:-}" "load_config: CB_TEST_LOADED_VAR loaded from config.env"
assert_eq "advanced_value" "${CB_TEST_ADVANCED_VAR:-}" "load_config: CB_TEST_ADVANCED_VAR loaded from advanced.env"

# ============================================================================
# 9. cb_persist_config_skeleton
# ============================================================================
t_info "--- cb_persist_config_skeleton ---"

# cb_persist_config_skeleton checks id -u == 0.
# In unit test we don't have root, so we mock the id command.
MOCK_DIR="$SANDBOX/mock_bin"
mkdir -p "$MOCK_DIR"
cat > "$MOCK_DIR/id" <<'IDEOF'
#!/bin/bash
# Mock: when asked for -u, return 0 (root)
for arg in "$@"; do
    [[ "$arg" == "-u" ]] && { echo "0"; exit 0; }
done
# Fallback to real id
/usr/bin/id "$@"
IDEOF
chmod +x "$MOCK_DIR/id"

# Delete existing config so persist can create a new one
rm -f "$CB_CONFIG_FILE"
(
    export PATH="$MOCK_DIR:$PATH"
    # Re-source common.sh in subshell with id mock
    unset _CB_COMMON_LOADED
    source "$CB_REPO_ROOT/lib/common.sh" 2>/dev/null
    cb_persist_config_skeleton "admin@test.com" "test.example.com" "letsencrypt" 2>/dev/null
)
assert_file_exists "$CB_CONFIG_FILE" "persist_skeleton: config.env created"
skeleton_content=$(cat "$CB_CONFIG_FILE")
assert_contains "$skeleton_content" "admin@test.com" "persist_skeleton: email present"
assert_contains "$skeleton_content" "test.example.com" "persist_skeleton: domain present"
assert_contains "$skeleton_content" 'CB_CA="letsencrypt"' "persist_skeleton: CA present"

# Second call does not overwrite existing config
echo "EXISTING=1" > "$CB_CONFIG_FILE"
(
    export PATH="$MOCK_DIR:$PATH"
    unset _CB_COMMON_LOADED
    source "$CB_REPO_ROOT/lib/common.sh" 2>/dev/null
    cb_persist_config_skeleton "new@test.com" "new.example.com" "harica" 2>/dev/null
)
preserve_content=$(cat "$CB_CONFIG_FILE")
assert_contains "$preserve_content" "EXISTING=1" "persist_skeleton: existing config.env is not overwritten"
assert_not_contains "$preserve_content" "new@test.com" "persist_skeleton: new email was not written"

# ============================================================================
# 10. cb_require_cmd
# ============================================================================
t_info "--- cb_require_cmd ---"

# Existing commands -> no error
cb_require_cmd bash echo
assert_eq 0 $? "require_cmd: bash and echo exist"

# Missing command -> die (subshell so it does not terminate whole test)
out=$(cb_require_cmd "__neexistujici_prikaz_xyz__" 2>&1) ; rc=$?
assert_eq 1 $rc "require_cmd: missing command -> die (rc 1)"
assert_contains "$out" "Missing commands" "require_cmd: error message contains 'Missing commands'"

# Mix of existing and non-existing
out=$(cb_require_cmd bash "__fake_cmd__" 2>&1) ; rc=$?
assert_eq 1 $rc "require_cmd: mix of existing and non-existing -> die"
assert_contains "$out" "__fake_cmd__" "require_cmd: prints the missing command"

# ============================================================================
# 11. cb_mark_installed / cb_is_installed
# ============================================================================
t_info "--- cb_mark_installed / cb_is_installed ---"

# Before marking -> not installed
cb_is_installed "test-component"
assert_eq 1 $? "is_installed: unmarked component -> rc 1"

# Mark it
cb_mark_installed "test-component"
assert_eq 0 $? "mark_installed: successful marking"

# After marking -> installed
cb_is_installed "test-component"
assert_eq 0 $? "is_installed: marked component -> rc 0"

# Different component -> still not marked
cb_is_installed "other-component"
assert_eq 1 $? "is_installed: different component is not marked"

# Marker file contains timestamp
marker_file="$CB_STATE_DIR/installed/test-component.marker"
assert_file_exists "$marker_file" "mark_installed: marker file exists"
marker_val=$(cat "$marker_file")
assert_match "$marker_val" '^[0-9]+$' "mark_installed: marker contains unix timestamp"

# ============================================================================
# 12. Service management - _cb_has_systemd detekce
# ============================================================================
t_info "--- _cb_has_systemd detection ---"

# _cb_has_systemd checks: command -v systemctl && -d /run/systemd/system
# In the test environment the result cannot be guaranteed, so we verify the logic
if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    _cb_has_systemd
    assert_eq 0 $? "has_systemd: systemctl + /run/systemd/system -> true"
    t_info "systemd detected on this machine"
else
    _cb_has_systemd 2>/dev/null
    rc=$?
    assert_ne 0 "$rc" "has_systemd: without systemctl or /run/systemd -> false"
    t_info "systemd not available (expected in container/CI)"
fi

# Test cb_svc_* with mocked systemctl
SVC_MOCK_DIR="$SANDBOX/svc_mock"
mkdir -p "$SVC_MOCK_DIR"

# Mock systemctl that always succeeds and logs operations
cat > "$SVC_MOCK_DIR/systemctl" <<'SCTLEOF'
#!/bin/bash
echo "systemctl $*" >> "${CB_SVC_MOCK_LOG:-/dev/null}"
exit 0
SCTLEOF
chmod +x "$SVC_MOCK_DIR/systemctl"

# Fake /run/systemd/system for detection
FAKE_RUN="$SANDBOX/fake_run"
mkdir -p "$FAKE_RUN/systemd/system"

export CB_SVC_MOCK_LOG="$SANDBOX/svc_calls.log"
: > "$CB_SVC_MOCK_LOG"

# In a subshell with mock we test cb_svc_reload
(
    export PATH="$SVC_MOCK_DIR:$PATH"
    # Override _cb_has_systemd to use our fake /run
    _cb_has_systemd() {
        command -v systemctl >/dev/null 2>&1 && [[ -d "$FAKE_RUN/systemd/system" ]]
    }
    _cb_has_systemd && cb_svc_reload "nginx" 2>/dev/null
)
svc_log=$(cat "$CB_SVC_MOCK_LOG")
assert_contains "$svc_log" "systemctl reload nginx" "svc_reload: calls systemctl reload nginx"

# Test cb_svc_restart via mock
: > "$CB_SVC_MOCK_LOG"
(
    export PATH="$SVC_MOCK_DIR:$PATH"
    _cb_has_systemd() {
        command -v systemctl >/dev/null 2>&1 && [[ -d "$FAKE_RUN/systemd/system" ]]
    }
    _cb_has_systemd && cb_svc_restart "apache2" 2>/dev/null
)
svc_log=$(cat "$CB_SVC_MOCK_LOG")
assert_contains "$svc_log" "systemctl restart apache2" "svc_restart: calls systemctl restart apache2"

# ============================================================================
# Additional tests: cb_snapshot_restore with nonexistent file
# ============================================================================
t_info "--- additional edge-case tests ---"

out=$(cb_snapshot_restore "/nonexistent/snapshot.tar.gz" 2>&1)
assert_eq 1 $? "snapshot_restore: nonexistent file -> rc 1"

# cb_snapshot_restore without arguments and empty CB_LAST_SNAPSHOT -> rc 1
CB_LAST_SNAPSHOT=""
out=$(cb_snapshot_restore 2>&1)
assert_eq 1 $? "snapshot_restore: empty CB_LAST_SNAPSHOT -> rc 1"

# cb_validate_domain: trailing dot (FQDN with dot) - not allowed by regex
cb_validate_domain "example.com."
assert_eq 1 $? "domain: trailing dot (example.com.) invalid"

# cb_validate_email: multiple @ is invalid
cb_validate_email "user@@example.com"
assert_eq 1 $? "email: double @ is invalid"

# cb_apply_cli_set: empty value is OK (e.g. CB_ACME_URL=)
cb_apply_cli_set "CB_EMPTY_VAL="
assert_eq 0 $? "cli_set: empty value is allowed"
assert_eq "" "$CB_EMPTY_VAL" "cli_set: empty value set"

# cb_retry: command with arguments
cb_retry 1 0 test "1" = "1"
assert_eq 0 $? "retry: test 1 = 1 succeeds"

cb_retry 1 0 test "1" = "2"
assert_eq 1 $? "retry: test 1 = 2 fails"

# cb_mark_installed: multiple components at once
cb_mark_installed "comp-a"
cb_mark_installed "comp-b"
cb_is_installed "comp-a" && cb_is_installed "comp-b"
assert_eq 0 $? "mark_installed: multiple components coexist"

t_summary
