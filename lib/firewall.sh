#!/bin/bash
# certberus/lib/firewall.sh
# Firewall detection and manipulation.
# Supported backends: firewalld, ufw, nftables, iptables (legacy and nft),
# "docker" (detection that we are inside a container), "none".
[[ -n "${_CB_FW_LOADED:-}" ]] && return 0
_CB_FW_LOADED=1

# -------- Detection --------
# Sets CB_FW_BACKEND to one of: firewalld, ufw, nftables, iptables-nft,
# iptables-legacy, docker, none
cb_firewall_detect() {
    CB_FW_BACKEND="none"

    # Docker/container detection
    if [[ -f /.dockerenv ]] || grep -qa 'docker\|lxc\|containerd' /proc/1/cgroup 2>/dev/null; then
        CB_FW_BACKEND="docker"
    fi

    # firewalld (RHEL/CentOS default)
    if command -v firewall-cmd >/dev/null 2>&1 && \
       systemctl is-active --quiet firewalld 2>/dev/null; then
        CB_FW_BACKEND="firewalld"
        export CB_FW_BACKEND
        return 0
    fi

    # ufw (Ubuntu)
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        CB_FW_BACKEND="ufw"
        export CB_FW_BACKEND
        return 0
    fi

    # nftables native
    if command -v nft >/dev/null 2>&1 && \
       systemctl is-active --quiet nftables 2>/dev/null; then
        CB_FW_BACKEND="nftables"
        export CB_FW_BACKEND
        return 0
    fi

    # iptables - determine backend
    if command -v iptables >/dev/null 2>&1; then
        if iptables -V 2>&1 | grep -q 'nf_tables'; then
            CB_FW_BACKEND="iptables-nft"
        else
            CB_FW_BACKEND="iptables-legacy"
        fi
    fi

    export CB_FW_BACKEND
}

cb_firewall_backend_pretty() {
    case "$CB_FW_BACKEND" in
        firewalld)       echo "firewalld (firewall-cmd)" ;;
        ufw)             echo "UFW (Uncomplicated Firewall)" ;;
        nftables)        echo "nftables (nft)" ;;
        iptables-nft)    echo "iptables (nf_tables backend)" ;;
        iptables-legacy) echo "iptables (legacy)" ;;
        docker)          echo "container (host-managed)" ;;
        none)            echo "no active firewall" ;;
    esac
}

# -------- Reachability inspection --------
# cb_firewall_port_open_to_world PROTO PORT
# Inspects the active firewall ruleset (no network probe, no domain needed) and
# reports whether an arbitrary host on the internet could reach PROTO/PORT.
# Echoes exactly one of:
#   open    - default-accept policy, or an unrestricted ACCEPT for the port
#   closed  - default-drop/reject policy with no unrestricted ACCEPT found
#   unknown - no readable/managed firewall, or the ruleset could not be parsed
# Biased away from a false "closed": when in doubt it returns "unknown", never
# "closed" - a wrong "closed" would block an otherwise working install.
cb_firewall_port_open_to_world() {
    local proto="$1" port="$2"
    case "$CB_FW_BACKEND" in
        none)
            echo "open"; return 0 ;;          # nothing in the way
        docker)
            echo "unknown"; return 0 ;;        # host-managed, not ours to read
        firewalld)
            if firewall-cmd --query-port="${port}/${proto}" >/dev/null 2>&1; then
                echo "open"
            else
                echo "closed"
            fi
            return 0 ;;
        ufw)
            local us; us="$(ufw status 2>/dev/null)" || { echo "unknown"; return 0; }
            [[ -z "$us" ]] && { echo "unknown"; return 0; }
            if printf '%s\n' "$us" | grep -qE "(^|[[:space:]])${port}/${proto}([[:space:]]|$).*ALLOW"; then
                echo "open"
            else
                echo "closed"
            fi
            return 0 ;;
        nftables)
            local rs; rs="$(nft list ruleset 2>/dev/null)" || { echo "unknown"; return 0; }
            [[ -z "$rs" ]] && { echo "unknown"; return 0; }
            if printf '%s\n' "$rs" | grep -qE "${proto} dport (${port}\b|\{[^}]*\b${port}\b[^}]*\}).*accept"; then
                echo "open"
            else
                echo "closed"
            fi
            return 0 ;;
        iptables-nft|iptables-legacy)
            local dump; dump="$(iptables-save -t filter 2>/dev/null)" || { echo "unknown"; return 0; }
            [[ -z "$dump" ]] && { echo "unknown"; return 0; }
            local pol
            pol="$(printf '%s\n' "$dump" | sed -n 's/^:INPUT \([A-Z]*\).*/\1/p')"
            [[ -z "$pol" ]] && { echo "unknown"; return 0; }
            if [[ "$pol" != "DROP" && "$pol" != "REJECT" ]]; then
                echo "open"; return 0          # default-accept INPUT policy
            fi
            # Default-drop policy: look for an ACCEPT rule that an arbitrary
            # internet host could match - i.e. -j ACCEPT, this proto, this port
            # (or no port match at all), with no source restriction (-s), not
            # loopback (-i lo), and not a conntrack/state rule.
            local line
            while IFS= read -r line; do
                [[ "$line" == "-A "*" -j ACCEPT"* ]] || continue
                [[ "$line" == *" -s "*      ]] && continue
                [[ "$line" == *" -i lo"*    ]] && continue
                [[ "$line" == *"--ctstate"* ]] && continue
                [[ "$line" == *"--state "*  ]] && continue
                # proto: must be this proto, or unspecified
                [[ "$line" == *" -p "* && "$line" != *" -p ${proto} "* && "$line" != *" -p ${proto}" ]] && continue
                # port: explicit --dport PORT, a multiport list containing PORT,
                # or no port match at all (rule matches every port)
                if [[ "$line" == *"--dport ${port} "* || "$line" == *"--dport ${port}" ]]; then
                    echo "open"; return 0
                fi
                if [[ "$line" == *"--dports "* && "$line" == *"${port}"* ]]; then
                    echo "open"; return 0      # multiport - loose match, biased to open
                fi
                if [[ "$line" != *"--dport"* && "$line" != *"--dports"* && "$line" != *"--sport"* ]]; then
                    echo "open"; return 0      # accepts regardless of port
                fi
            done <<< "$dump"
            echo "closed"; return 0 ;;
        *)
            echo "unknown"; return 0 ;;
    esac
}

# -------- Open port --------
# cb_firewall_open_port PROTO PORT [COMMENT]
cb_firewall_open_port() {
    local proto="$1" port="$2" comment="${3:-certberus}"

    if [[ "$CB_DRY_RUN" == "1" ]]; then
        cb_log "[DRY-RUN] Open $proto/$port ($CB_FW_BACKEND)"
        return 0
    fi

    case "$CB_FW_BACKEND" in
        firewalld)
            firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null 2>&1 && \
            firewall-cmd --reload >/dev/null 2>&1 && \
            cb_ok "firewalld: port $proto/$port opened"
            ;;
        ufw)
            ufw allow "${port}/${proto}" >/dev/null 2>&1 && \
            cb_ok "ufw: port $proto/$port opened"
            ;;
        nftables)
            # Idempotent: check both set syntax (e.g. "dport { 80, 443 }")
            if nft list ruleset 2>/dev/null | grep -qE "${proto} dport (${port}|[{][^}]*\b${port}\b[^}]*[}]).*accept"; then
                cb_debug "nftables: $proto/$port already open"
                return 0
            fi
            # insert (not add) - rules must be placed before catch-all drop
            if nft list table inet filter >/dev/null 2>&1; then
                nft insert rule inet filter input "$proto" dport "$port" accept 2>/dev/null && \
                cb_ok "nftables: port $proto/$port opened (runtime)" || \
                cb_warn "nftables: failed to add rule"
                cb_warn "Note: for persistence, add the rule to /etc/nftables.conf"
            else
                cb_warn "nftables: table 'inet filter' does not exist, skipping"
            fi
            ;;
        iptables-nft|iptables-legacy)
            if iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT \
                -m comment --comment "$comment" 2>/dev/null; then
                cb_debug "iptables: $proto/$port already open"
                return 0
            fi
            iptables -I INPUT -p "$proto" --dport "$port" -j ACCEPT \
                -m comment --comment "$comment" && \
            cb_ok "iptables: port $proto/$port opened"
            # Persistent save (if available)
            if command -v netfilter-persistent >/dev/null 2>&1; then
                netfilter-persistent save >/dev/null 2>&1 || true
            elif command -v iptables-save >/dev/null 2>&1 && [[ -d /etc/iptables ]]; then
                iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            fi
            ;;
        docker|none)
            cb_debug "Firewall: no action ($CB_FW_BACKEND)"
            ;;
    esac
}

# Close port (only if we added it - identified by comment)
cb_firewall_close_port() {
    local proto="$1" port="$2" comment="${3:-certberus}"

    if [[ "$CB_DRY_RUN" == "1" ]]; then
        cb_log "[DRY-RUN] Close $proto/$port ($CB_FW_BACKEND)"
        return 0
    fi

    case "$CB_FW_BACKEND" in
        firewalld)
            firewall-cmd --permanent --remove-port="${port}/${proto}" >/dev/null 2>&1 && \
            firewall-cmd --reload >/dev/null 2>&1
            ;;
        ufw)
            ufw delete allow "${port}/${proto}" >/dev/null 2>&1
            ;;
        iptables-nft|iptables-legacy)
            iptables -D INPUT -p "$proto" --dport "$port" -j ACCEPT \
                -m comment --comment "$comment" 2>/dev/null || true
            ;;
    esac
}

# Shortcut: Certberus needs TCP 80 and 443.
cb_firewall_ensure_http_https() {
    cb_firewall_open_port tcp 80  "certberus-http"
    cb_firewall_open_port tcp 443 "certberus-https"
}

# ACME firewall policy.
#
# HARICA/CESNET EAB for pre-validated organizations often does not need
# Certberus to automatically open the local firewall. We keep webroot/HTTP-01
# preparation in place, but firewall mutations are opt-in for HARICA.
cb_firewall_acme_auto_open_enabled() {
    # Default OFF: certberus does not have to be the only firewall guardian (managed FW,
    # site rules, fail2ban, ...). Admin opt-in: --firewall / CB_FIREWALL_AUTO_OPEN=1.
    [[ "${CB_FIREWALL_AUTO_OPEN:-0}" == "1" ]] || return 1

    if [[ "${CB_CA:-}" == "harica" && "${CB_HARICA_FIREWALL_AUTO_OPEN:-0}" != "1" ]]; then
        if [[ -z "${_CB_HARICA_FIREWALL_WARNED:-}" ]]; then
            cb_warn "CA=harica/EAB: skipping automatic firewall opening."
            cb_warn "If HARICA returns HTTP-01 timeout, open ports 80/443 manually or set CB_HARICA_FIREWALL_AUTO_OPEN=1."
            _CB_HARICA_FIREWALL_WARNED=1
            export _CB_HARICA_FIREWALL_WARNED
        fi
        return 1
    fi

    return 0
}

cb_firewall_ensure_http_https_for_acme() {
    cb_firewall_acme_auto_open_enabled || return 0
    cb_firewall_ensure_http_https
}

# Tomcat helper: redirect 80 -> 8080 (firewalld/iptables/nft only).
# After DNAT, dport changes to the target port, so the input chain must
# accept the target port - otherwise packets are dropped.
cb_firewall_redirect_80_to() {
    local target="${1:-8080}"
    case "$CB_FW_BACKEND" in
        firewalld)
            firewall-cmd --permanent \
                --add-forward-port=port=80:proto=tcp:toport="$target" >/dev/null 2>&1 && \
            firewall-cmd --permanent --add-port="${target}/tcp" >/dev/null 2>&1 && \
            firewall-cmd --reload >/dev/null 2>&1 && \
            cb_ok "firewalld: redirect 80 -> $target (+ accept $target)"
            ;;
        iptables-nft|iptables-legacy)
            iptables -t nat -C PREROUTING -p tcp --dport 80 -j REDIRECT \
                --to-port "$target" 2>/dev/null || \
            iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT \
                --to-port "$target"
            if ! iptables -C INPUT -p tcp --dport "$target" -j ACCEPT \
                -m comment --comment "certberus-redirect" 2>/dev/null; then
                iptables -I INPUT -p tcp --dport "$target" -j ACCEPT \
                    -m comment --comment "certberus-redirect"
            fi
            cb_ok "iptables nat: redirect 80 -> $target (+ accept $target)"
            cb_warn "For persistence save: iptables-save or netfilter-persistent save"
            ;;
        nftables)
            # Check if prerouting chain already exists
            local chain_exists=0
            nft list chain ip nat prerouting >/dev/null 2>&1 && chain_exists=1
            if (( chain_exists == 0 )); then
                nft 'add table ip nat' 2>/dev/null || true
                nft 'add chain ip nat prerouting { type nat hook prerouting priority -100 ; }' 2>/dev/null || true
            fi
            # Idempotently add redirect rule
            if ! nft list chain ip nat prerouting 2>/dev/null | grep -qE "tcp dport 80 redirect to :?$target\b"; then
                if nft "add rule ip nat prerouting tcp dport 80 redirect to :$target" 2>/dev/null; then
                    cb_ok "nftables: redirect 80 -> $target (runtime)"
                else
                    cb_warn "nftables redirect failed - add manually:"
                    cb_warn "  table ip nat { chain prerouting { type nat hook prerouting priority -100;"
                    cb_warn "                  tcp dport 80 redirect to :$target } }"
                    return 1
                fi
            else
                cb_ok "nftables: redirect 80 -> $target (already exists)"
            fi
            # After DNAT, packets arrive at input with dport=target - must be accepted
            _cb_nft_ensure_input_accept tcp "$target"
            ;;
        *)
            cb_warn "Redirect 80->${target} is not supported for $CB_FW_BACKEND"
            return 1
            ;;
    esac
}

# Helper: idempotently add accept rule to nftables input chain.
# Searches both inet filter input and ip filter input (different distros).
_cb_nft_ensure_input_accept() {
    local proto="$1" port="$2"
    if nft list ruleset 2>/dev/null | grep -qE "${proto} dport (${port}|[{][^}]*\b${port}\b[^}]*[}]).*accept"; then
        cb_debug "nftables: $proto/$port already accepted in input"
        return 0
    fi
    local family chain_found=0
    for family in inet ip; do
        if nft list chain "$family" filter input >/dev/null 2>&1; then
            nft insert rule "$family" filter input "$proto" dport "$port" accept 2>/dev/null && \
                chain_found=1 && break
        fi
    done
    if (( chain_found )); then
        cb_ok "nftables: accept $proto/$port added to input chain (runtime)"
        cb_warn "For persistence, add the rule to /etc/nftables.conf"
    else
        cb_warn "nftables: input chain not found for accept $proto/$port"
        cb_warn "Verify manually: nft list ruleset, and add accept rule for port $port"
    fi
}

# -------- Snapshot --------
cb_firewall_snapshot() {
    local ts; ts="$(date +%Y%m%d-%H%M%S)"
    local dir="$CB_BACKUP_DIR/firewall-$ts"
    mkdir -p "$dir" 2>/dev/null || return 1
    case "$CB_FW_BACKEND" in
        firewalld)
            firewall-cmd --list-all-zones > "$dir/firewalld-zones.txt" 2>/dev/null || true
            ;;
        ufw)
            ufw status verbose > "$dir/ufw-status.txt" 2>/dev/null || true
            ;;
        nftables)
            nft list ruleset > "$dir/nftables.conf" 2>/dev/null || true
            ;;
        iptables-nft|iptables-legacy)
            iptables-save > "$dir/iptables.rules" 2>/dev/null || true
            ip6tables-save > "$dir/ip6tables.rules" 2>/dev/null || true
            ;;
    esac
    cb_ok "Firewall snapshot: $dir"
    CB_LAST_FW_SNAPSHOT="$dir"
    printf '%s' "$dir"
}

# Initialize
cb_firewall_detect
