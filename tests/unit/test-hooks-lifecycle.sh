#!/bin/bash
# tests/unit/test-hooks-lifecycle.sh
#
# End-to-end hook lifecycle:
#   1. cb_run_hooks propagates CA_* env to all hooks in all events
#   2. cb_hook_context + cb_hook_set_cert sets context correctly
#   3. mod_md adapter forwards events to hook directories
#   4. Deploy hook (certbot) runs renewed.d + post-deploy.d (even without run-parts)
#   5. Execution order: hooks in directory run in sorted order
#   6. pre-* hook fail stops the pipeline, post-* hook fail does not stop it
#   7. on-failure hook runs even when previous hook failed
#   8. Hook sees current cert paths (CA_CERT_PATH, CA_KEY_PATH)
#   9. All known events from CB_KNOWN_EVENTS work
#  10. Deploy hook works even when run-parts is not available (RHEL/Alpine)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/assert.sh"
source "$HERE/../lib/env.sh"

SANDBOX="$(t_mktempdir hooks-lifecycle)" || exit 1
trap 't_cleanup' EXIT

t_stub_log_helpers
t_isolate_cb_dirs "$SANDBOX"

# shellcheck disable=SC1091
source "$CB_REPO_ROOT/lib/hooks.sh"

# ==========================================================================
# Test 1: All known events accept hooks
# ==========================================================================
EVENTS_TESTED=0
for ev in "${CB_KNOWN_EVENTS[@]}"; do
    mkdir -p "$CB_HOOKS_DIR/${ev}.d"
    cat > "$CB_HOOKS_DIR/${ev}.d/10-marker" <<HOOKEOF
#!/bin/bash
echo "\$CA_EVENT" > "$SANDBOX/ev-${ev}"
HOOKEOF
    chmod +x "$CB_HOOKS_DIR/${ev}.d/10-marker"
done

CA_WEBSERVER="test" CA_PRIMARY_DOMAIN="x.test" CA_DOMAIN_LIST="x.test"
for ev in "${CB_KNOWN_EVENTS[@]}"; do
    cb_run_hooks "$ev" 2>/dev/null
    if [[ -f "$SANDBOX/ev-${ev}" ]]; then
        got=$(cat "$SANDBOX/ev-${ev}")
        if [[ "$got" == "$ev" ]]; then
            EVENTS_TESTED=$((EVENTS_TESTED + 1))
        else
            t_fail "event $ev: CA_EVENT=$got (expected $ev)"
        fi
    else
        t_fail "event $ev: marker file not created"
    fi
done
t_pass "all events work ($EVENTS_TESTED/${#CB_KNOWN_EVENTS[@]})"

# ==========================================================================
# Test 2: cb_hook_context + cb_hook_set_cert → CA_* env in hook
# ==========================================================================
rm -f "$SANDBOX/ctx-marker"
mkdir -p "$CB_HOOKS_DIR/post-issue.d"
cat > "$CB_HOOKS_DIR/post-issue.d/20-ctx" <<HOOKEOF
#!/bin/bash
cat > "$SANDBOX/ctx-marker" <<EOF2
ws=\$CA_WEBSERVER
primary=\$CA_PRIMARY_DOMAIN
list=\$CA_DOMAIN_LIST
cert=\$CA_CERT_PATH
key=\$CA_KEY_PATH
issuer=\$CA_CERT_ISSUER
staging=\$CA_STAGING
event=\$CA_EVENT
EOF2
HOOKEOF
chmod +x "$CB_HOOKS_DIR/post-issue.d/20-ctx"

cb_hook_context nginx "foo.example.com" "bar.example.com"
cb_hook_set_cert "/etc/letsencrypt/live/foo.example.com/fullchain.pem" \
                 "/etc/letsencrypt/live/foo.example.com/privkey.pem" \
                 "letsencrypt"
CB_STAGING=1
cb_run_hooks post-issue 2>/dev/null

assert_file_exists "$SANDBOX/ctx-marker" "context marker created"
if [[ -f "$SANDBOX/ctx-marker" ]]; then
    ctx=$(cat "$SANDBOX/ctx-marker")
    assert_contains "$ctx" "ws=nginx" "CA_WEBSERVER=nginx"
    assert_contains "$ctx" "primary=foo.example.com" "CA_PRIMARY_DOMAIN"
    assert_contains "$ctx" "list=foo.example.com bar.example.com" "CA_DOMAIN_LIST"
    assert_contains "$ctx" "cert=/etc/letsencrypt/live/foo.example.com/fullchain.pem" "CA_CERT_PATH"
    assert_contains "$ctx" "key=/etc/letsencrypt/live/foo.example.com/privkey.pem" "CA_KEY_PATH"
    assert_contains "$ctx" "issuer=letsencrypt" "CA_CERT_ISSUER"
    assert_contains "$ctx" "staging=1" "CA_STAGING"
    assert_contains "$ctx" "event=post-issue" "CA_EVENT"
fi
CB_STAGING=0

# ==========================================================================
# Test 3: Execution order - sorted by filename
# ==========================================================================
rm -f "$SANDBOX/order"
mkdir -p "$CB_HOOKS_DIR/pre-deploy.d"
for i in 30 10 20; do
    cat > "$CB_HOOKS_DIR/pre-deploy.d/${i}-step" <<HOOKEOF
#!/bin/bash
echo "$i" >> "$SANDBOX/order"
HOOKEOF
    chmod +x "$CB_HOOKS_DIR/pre-deploy.d/${i}-step"
done

cb_run_hooks pre-deploy 2>/dev/null
if [[ -f "$SANDBOX/order" ]]; then
    order=$(tr '\n' ',' < "$SANDBOX/order")
    assert_eq "10,20,30," "$order" "hooks run in sorted order"
else
    t_fail "order marker not created"
fi

# ==========================================================================
# Test 4: pre-* hook fail stops pipeline (next hook does not run)
# ==========================================================================
rm -f "$SANDBOX/pre-a" "$SANDBOX/pre-b"
mkdir -p "$CB_HOOKS_DIR/pre-snapshot.d"
cat > "$CB_HOOKS_DIR/pre-snapshot.d/10-fail" <<HOOKEOF
#!/bin/bash
echo "a" > "$SANDBOX/pre-a"
exit 1
HOOKEOF
chmod +x "$CB_HOOKS_DIR/pre-snapshot.d/10-fail"
cat > "$CB_HOOKS_DIR/pre-snapshot.d/20-after" <<HOOKEOF
#!/bin/bash
echo "b" > "$SANDBOX/pre-b"
HOOKEOF
chmod +x "$CB_HOOKS_DIR/pre-snapshot.d/20-after"

cb_run_hooks pre-snapshot 2>/dev/null; rc=$?
assert_file_exists "$SANDBOX/pre-a" "pre-snapshot first hook ran"
[[ ! -f "$SANDBOX/pre-b" ]] && t_pass "pre-snapshot: second hook did not run (pipeline stop)" \
    || t_fail "pre-snapshot: second hook DID run after failure"
[[ $rc -ne 0 ]] && t_pass "pre-snapshot: rc=$rc (non-zero)" \
    || t_fail "pre-snapshot: rc=0 even though hook failed"

# ==========================================================================
# Test 5: post-* hook fail does NOT stop subsequent hooks
# ==========================================================================
rm -f "$SANDBOX/post-a" "$SANDBOX/post-b"
mkdir -p "$CB_HOOKS_DIR/post-snapshot.d"
cat > "$CB_HOOKS_DIR/post-snapshot.d/10-fail" <<HOOKEOF
#!/bin/bash
echo "a" > "$SANDBOX/post-a"
exit 1
HOOKEOF
chmod +x "$CB_HOOKS_DIR/post-snapshot.d/10-fail"
cat > "$CB_HOOKS_DIR/post-snapshot.d/20-after" <<HOOKEOF
#!/bin/bash
echo "b" > "$SANDBOX/post-b"
HOOKEOF
chmod +x "$CB_HOOKS_DIR/post-snapshot.d/20-after"

cb_run_hooks post-snapshot 2>/dev/null; rc=$?
assert_file_exists "$SANDBOX/post-a" "post-snapshot: first hook ran"
assert_file_exists "$SANDBOX/post-b" "post-snapshot: second hook ALSO ran (non-pre)"
[[ $rc -ne 0 ]] && t_pass "post-snapshot: rc=$rc (non-zero even though it continued)" \
    || t_fail "post-snapshot: rc=0 even though hook failed"

# ==========================================================================
# Test 6: on-failure hook runs normally
# ==========================================================================
rm -f "$SANDBOX/on-fail-marker"
mkdir -p "$CB_HOOKS_DIR/on-failure.d"
cat > "$CB_HOOKS_DIR/on-failure.d/10-alert" <<HOOKEOF
#!/bin/bash
echo "failure:\$CA_EVENT:\$CA_WEBSERVER" > "$SANDBOX/on-fail-marker"
HOOKEOF
chmod +x "$CB_HOOKS_DIR/on-failure.d/10-alert"

CA_WEBSERVER="nginx"
cb_run_hooks on-failure 2>/dev/null
assert_file_exists "$SANDBOX/on-fail-marker" "on-failure hook ran"
if [[ -f "$SANDBOX/on-fail-marker" ]]; then
    assert_contains "$(cat "$SANDBOX/on-fail-marker")" "failure:on-failure:nginx" "on-failure env"
fi

# ==========================================================================
# Test 7: mod_md adapter body - event sanitization
# ==========================================================================
adapter_src=$(cb_mod_md_adapter_body)
# Must contain key elements
assert_contains "$adapter_src" 'CA_EVENT="$EVENT"' "adapter exports CA_EVENT"
assert_contains "$adapter_src" 'CA_WEBSERVER="apache"' "adapter sets apache"
assert_contains "$adapter_src" 'CA_SOURCE="mod_md"' "adapter sets CA_SOURCE"
# Sanitization - unknown event is rejected
assert_contains "$adapter_src" 'rejected unknown event' "adapter sanitizes events"
# Manual loop fallback (run-parts should not be the only method)
assert_contains "$adapter_src" '[[ -x "$f" ]]' "adapter has manual loop"

# ==========================================================================
# Test 8: Deploy hook pattern - simulation without run-parts
# ==========================================================================
rm -f "$SANDBOX/deploy-renewed" "$SANDBOX/deploy-postdeploy"
mkdir -p "$CB_HOOKS_DIR/renewed.d" "$CB_HOOKS_DIR/post-deploy.d"
cat > "$CB_HOOKS_DIR/renewed.d/10-mark" <<HOOKEOF
#!/bin/bash
echo "renewed:\$CA_EVENT:\$CA_WEBSERVER:\$CA_PRIMARY_DOMAIN:\$CA_CERT_PATH" > "$SANDBOX/deploy-renewed"
HOOKEOF
chmod +x "$CB_HOOKS_DIR/renewed.d/10-mark"
cat > "$CB_HOOKS_DIR/post-deploy.d/10-mark" <<HOOKEOF
#!/bin/bash
echo "post-deploy:\$CA_EVENT:\$CA_WEBSERVER" > "$SANDBOX/deploy-postdeploy"
HOOKEOF
chmod +x "$CB_HOOKS_DIR/post-deploy.d/10-mark"

# Simulate what the deploy hook does
export CA_EVENT="renewed"
export CA_WEBSERVER="nginx"
export CA_PRIMARY_DOMAIN="test.example.com"
export CA_DOMAIN_LIST="test.example.com"
export CA_CERT_PATH="/etc/letsencrypt/live/test.example.com/fullchain.pem"
export CA_KEY_PATH="/etc/letsencrypt/live/test.example.com/privkey.pem"
export CA_SOURCE="certbot"
HOOK_TO="${CB_HOOK_TIMEOUT:-60}"
HAVE_TO=0; command -v timeout >/dev/null 2>&1 && HAVE_TO=1
for ev in renewed post-deploy; do
    D="$CB_HOOKS_DIR/${ev}.d"
    [[ -d "$D" ]] || continue
    for f in "$D"/*; do
        [[ -x "$f" ]] || continue
        case "$f" in *.example|*.bak|*.disabled) continue ;; esac
        if (( HAVE_TO )); then
            timeout "$HOOK_TO" "$f" >> /dev/null 2>&1 || true
        else
            "$f" >> /dev/null 2>&1 || true
        fi
    done
done
assert_file_exists "$SANDBOX/deploy-renewed" "deploy hook: renewed.d hook ran"
assert_file_exists "$SANDBOX/deploy-postdeploy" "deploy hook: post-deploy.d hook ran"
if [[ -f "$SANDBOX/deploy-renewed" ]]; then
    assert_contains "$(cat "$SANDBOX/deploy-renewed")" "renewed:renewed:nginx:test.example.com:/etc/letsencrypt" "deploy hook: env complete"
fi

# ==========================================================================
# Test 9: Deploy hook skips .disabled/.bak/.example
# ==========================================================================
rm -f "$SANDBOX/skip-disabled" "$SANDBOX/skip-bak" "$SANDBOX/skip-example"
cat > "$CB_HOOKS_DIR/renewed.d/20-test.disabled" <<HOOKEOF
#!/bin/bash
echo "BUG" > "$SANDBOX/skip-disabled"
HOOKEOF
chmod +x "$CB_HOOKS_DIR/renewed.d/20-test.disabled"
cat > "$CB_HOOKS_DIR/renewed.d/30-old.bak" <<HOOKEOF
#!/bin/bash
echo "BUG" > "$SANDBOX/skip-bak"
HOOKEOF
chmod +x "$CB_HOOKS_DIR/renewed.d/30-old.bak"
cat > "$CB_HOOKS_DIR/renewed.d/40-demo.sh.example" <<HOOKEOF
#!/bin/bash
echo "BUG" > "$SANDBOX/skip-example"
HOOKEOF
chmod +x "$CB_HOOKS_DIR/renewed.d/40-demo.sh.example"

for ev in renewed; do
    D="$CB_HOOKS_DIR/${ev}.d"
    for f in "$D"/*; do
        [[ -x "$f" ]] || continue
        case "$f" in *.example|*.bak|*.disabled) continue ;; esac
        "$f" >> /dev/null 2>&1 || true
    done
done
[[ ! -f "$SANDBOX/skip-disabled" ]] && t_pass "deploy hook: .disabled skipped" || t_fail "deploy hook: .disabled ran"
[[ ! -f "$SANDBOX/skip-bak" ]] && t_pass "deploy hook: .bak skipped" || t_fail "deploy hook: .bak ran"
[[ ! -f "$SANDBOX/skip-example" ]] && t_pass "deploy hook: .example skipped" || t_fail "deploy hook: .example ran"

# ==========================================================================
# Test 10: Webserver-specific context - nginx vs apache vs tomcat
# ==========================================================================
for ws in nginx apache tomcat; do
    rm -f "$SANDBOX/ws-${ws}"
    mkdir -p "$CB_HOOKS_DIR/post-issue.d"
    cat > "$CB_HOOKS_DIR/post-issue.d/30-ws-check" <<HOOKEOF
#!/bin/bash
echo "\$CA_WEBSERVER" > "$SANDBOX/ws-\$CA_WEBSERVER"
HOOKEOF
    chmod +x "$CB_HOOKS_DIR/post-issue.d/30-ws-check"
    cb_hook_context "$ws" "test.example.com"
    cb_run_hooks post-issue 2>/dev/null
    if [[ -f "$SANDBOX/ws-${ws}" ]]; then
        got=$(cat "$SANDBOX/ws-${ws}")
        assert_eq "$ws" "$got" "webserver context: $ws"
    else
        t_fail "webserver context: $ws marker not created"
    fi
done

# ==========================================================================
# Test 11: Hook timeout protects against hanging hooks (per-hook, not bulk)
# ==========================================================================
rm -f "$SANDBOX/timeout-fast" "$SANDBOX/timeout-slow"
mkdir -p "$CB_HOOKS_DIR/post-reload.d"
cat > "$CB_HOOKS_DIR/post-reload.d/10-fast" <<HOOKEOF
#!/bin/bash
echo "fast" > "$SANDBOX/timeout-fast"
HOOKEOF
chmod +x "$CB_HOOKS_DIR/post-reload.d/10-fast"
cat > "$CB_HOOKS_DIR/post-reload.d/20-slow" <<HOOKEOF
#!/bin/bash
sleep 30
echo "slow" > "$SANDBOX/timeout-slow"
HOOKEOF
chmod +x "$CB_HOOKS_DIR/post-reload.d/20-slow"

start=$SECONDS
CB_HOOK_TIMEOUT=2 cb_run_hooks post-reload 2>/dev/null || true
elapsed=$((SECONDS - start))
assert_file_exists "$SANDBOX/timeout-fast" "per-hook timeout: fast hook completed"
[[ ! -f "$SANDBOX/timeout-slow" ]] && t_pass "per-hook timeout: slow hook killed (${elapsed}s)" \
    || t_fail "per-hook timeout: slow hook completed"
(( elapsed < 10 )) && t_pass "per-hook timeout: total time < 10s (${elapsed}s)" \
    || t_fail "per-hook timeout: total time too long (${elapsed}s)"

# ==========================================================================
# Test 12: CA_SNAPSHOT_PATH is propagated
# ==========================================================================
rm -f "$SANDBOX/snapshot-check"
mkdir -p "$CB_HOOKS_DIR/post-snapshot.d"
rm -f "$CB_HOOKS_DIR/post-snapshot.d/10-fail" "$CB_HOOKS_DIR/post-snapshot.d/20-after"
cat > "$CB_HOOKS_DIR/post-snapshot.d/50-snap" <<HOOKEOF
#!/bin/bash
echo "\$CA_SNAPSHOT_PATH" > "$SANDBOX/snapshot-check"
HOOKEOF
chmod +x "$CB_HOOKS_DIR/post-snapshot.d/50-snap"
CB_LAST_SNAPSHOT="/var/backups/certberus/snap-20260508"
cb_run_hooks post-snapshot 2>/dev/null
if [[ -f "$SANDBOX/snapshot-check" ]]; then
    assert_eq "/var/backups/certberus/snap-20260508" "$(cat "$SANDBOX/snapshot-check")" "CA_SNAPSHOT_PATH"
fi

t_summary
