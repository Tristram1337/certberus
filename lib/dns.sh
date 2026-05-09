#!/bin/bash
# certberus/lib/dns.sh - DNS checks for ACME validation
[[ -n "${_CB_DNS_LOADED:-}" ]] && return 0
_CB_DNS_LOADED=1

# Returns a list of all local (globally-routable) IPv4 addresses - space-separated.
# Helps with NAT/multi-IP/floating IP scenarios where the public IP differs
# from the one shown by ipify.org (e.g. outgoing NAT vs. dest NAT).
cb_local_ipv4_list() {
    local out=""
    if command -v ip >/dev/null 2>&1; then
        out=$(ip -4 -o addr show scope global 2>/dev/null \
            | awk '{print $4}' | cut -d/ -f1 | tr '\n' ' ')
    fi
    if [[ -z "$out" ]] && command -v hostname >/dev/null 2>&1; then
        out=$(hostname -I 2>/dev/null | tr -s ' ' | tr ' ' '\n' \
            | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | tr '\n' ' ')
    fi
    printf '%s' "$out"
}

cb_local_ipv6_list() {
    local out=""
    if command -v ip >/dev/null 2>&1; then
        out=$(ip -6 -o addr show scope global 2>/dev/null \
            | awk '{print $4}' | cut -d/ -f1 | tr '\n' ' ')
    fi
    printf '%s' "$out"
}

# Returns the public IP of the server (IPv4). Cached in CB_SERVER_IP4.
# First tries an external service (handles NAT), on failure uses local interface.
cb_server_ipv4() {
    [[ -n "${CB_SERVER_IP4:-}" ]] && { printf '%s' "$CB_SERVER_IP4"; return 0; }
    local ip=""
    if command -v curl >/dev/null 2>&1; then
        for svc in \
            "https://api.ipify.org" \
            "https://ifconfig.me" \
            "https://checkip.amazonaws.com"; do
            ip=$(curl -m 4 -4 -s "$svc" 2>/dev/null | tr -d '[:space:]')
            [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] && break
            ip=""
        done
    fi
    if [[ -z "$ip" ]]; then
        # Air-gap fallback: take the first global IPv4 from local interfaces
        ip=$(cb_local_ipv4_list | awk '{print $1}')
    fi
    CB_SERVER_IP4="$ip"
    printf '%s' "$ip"
}

cb_server_ipv6() {
    [[ -n "${CB_SERVER_IP6:-}" ]] && { printf '%s' "$CB_SERVER_IP6"; return 0; }
    local ip=""
    if command -v curl >/dev/null 2>&1; then
        ip=$(curl -m 4 -6 -s "https://api64.ipify.org" 2>/dev/null | tr -d '[:space:]')
        [[ "$ip" == *:* ]] || ip=""
    fi
    if [[ -z "$ip" ]]; then
        ip=$(cb_local_ipv6_list | awk '{print $1}')
    fi
    CB_SERVER_IP6="$ip"
    printf '%s' "$ip"
}

# Resolves A records for a domain. Returns IP(s) separated by spaces.
cb_resolve_a() {
    local d="$1"
    if command -v dig >/dev/null 2>&1; then
        dig +time=2 +tries=1 +short A "$d" 2>/dev/null | grep -E '^[0-9.]+$' | tr '\n' ' '
    elif command -v host >/dev/null 2>&1; then
        host -W 2 -t A "$d" 2>/dev/null | awk '/has address/ {print $NF}' | tr '\n' ' '
    elif command -v getent >/dev/null 2>&1; then
        getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' '
    fi
}

cb_resolve_aaaa() {
    local d="$1"
    if command -v dig >/dev/null 2>&1; then
        dig +time=2 +tries=1 +short AAAA "$d" 2>/dev/null | grep -E ':' | tr '\n' ' '
    elif command -v host >/dev/null 2>&1; then
        host -W 2 -t AAAA "$d" 2>/dev/null | awk '/IPv6 address/ {print $NF}' | tr '\n' ' '
    elif command -v getent >/dev/null 2>&1; then
        getent ahostsv6 "$d" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' '
    fi
}

# Returns 0 if the domain points (A or AAAA) to this server, 1 otherwise.
# Note: exact match, not substring.
# Honors CB_SKIP_DNS_CHECK=1 (always returns 0) - for NAT/LB/floating IP scenarios
# where the server's public IP may not match the local interface.
cb_domain_points_here() {
    local d="$1"
    [[ "${CB_SKIP_DNS_CHECK:-0}" == "1" ]] && return 0

    local server4 server6 ip
    server4=$(cb_server_ipv4)
    server6=$(cb_server_ipv6)

    # Build a set of all IPs of this machine: public + all local interfaces.
    local locals4 locals6
    locals4=$(cb_local_ipv4_list)
    locals6=$(cb_local_ipv6_list)
    local all4=" $server4 $locals4 "
    local all6=" $server6 $locals6 "

    local matched4=0 matched6=0 has_a=0 has_aaaa=0
    for ip in $(cb_resolve_a "$d"); do
        has_a=1
        [[ "$all4" == *" $ip "* ]] && { matched4=1; break; }
    done
    for ip in $(cb_resolve_aaaa "$d"); do
        has_aaaa=1
        [[ "$all6" == *" $ip "* ]] && { matched6=1; break; }
    done

    # IPv6-only domain on IPv4-only server and vice versa: one match is enough
    (( matched4 || matched6 )) && return 0
    # Edge case: server has no IPv6, domain has only AAAA -> we cannot verify, but
    # if we got no A/AAAA at all, it is genuinely missing DNS.
    (( has_a || has_aaaa )) || return 1
    return 1
}

# CAA check - warns if the domain has a CAA record that blocks LE/HARICA.
# RFC 8659: when no CAA exists on the specific label, walk up the zone to the apex.
# cb_check_caa DOMAIN EXPECTED_ISSUER
cb_check_caa() {
    local d="$1" issuer="${2:-letsencrypt.org}"
    command -v dig >/dev/null 2>&1 || return 0

    # Walk-up: foo.bar.example.com -> bar.example.com -> example.com
    local cur="$d" caa=""
    while [[ -n "$cur" && "$cur" == *.* ]]; do
        caa=$(dig +time=2 +tries=1 +short CAA "$cur" 2>/dev/null)
        [[ -n "$caa" ]] && break
        # Strip leftmost label
        cur="${cur#*.}"
    done
    [[ -z "$caa" ]] && return 0  # no CAA in the entire zone = everything allowed

    # Use fixed-string match (issuer may contain regex metachars like dot).
    # Format CAA: '0 issue "letsencrypt.org"' - matching the exact value between quotes.
    if echo "$caa" | grep -qiF "issue \"${issuer}\""; then
        return 0
    fi
    # Also allowed with parameters: '0 issue "letsencrypt.org;validationmethods=http-01"'
    if echo "$caa" | grep -qiF "issue \"${issuer};"; then
        return 0
    fi
    if echo "$caa" | grep -qi 'issue "'; then
        cb_warn "CAA record (zone $cur) does not allow $issuer for $d:"
        echo "$caa" | sed 's/^/    /'
        return 1
    fi
    return 0
}
