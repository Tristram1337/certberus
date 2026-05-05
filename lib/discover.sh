#!/bin/bash
# certberus/lib/discover.sh
# Auto-discovery of domains and certificates. Three sources:
#   1. certbot certificates    -> already managed certs (SAN)
#   2. HTTPS of the live server -> openssl s_client SAN
#   3. webserver configuration -> apache VirtualHost / nginx server_name / tomcat Host
#
# Then filtered via cb_domain_points_here -> only domains that actually point here.
#
# API:
#   cb_discover_certbot_domains           -> stdout: domains (one per line)
#   cb_discover_https_san HOST[:PORT]     -> stdout: SAN list
#   cb_discover_apache_domains            -> stdout
#   cb_discover_nginx_domains             -> stdout
#   cb_discover_tomcat_domains            -> stdout
#   cb_discover_webserver_domains WS      -> delegates (ws: apache|nginx|tomcat|auto)
#   cb_filter_points_here DOM1 DOM2 ...   -> stdout: only those that resolve to us
#   cb_discover_all WEBSERVER             -> stdout: union of all sources, filtered, unique

[[ -n "${_CB_DISCOVER_LOADED:-}" ]] && return 0
_CB_DISCOVER_LOADED=1

# -------- Certbot --------
cb_discover_certbot_domains() {
    command -v certbot >/dev/null 2>&1 || return 0
    # Format:
    #    Certificate Name: example.com
    #      Domains: example.com www.example.com
    certbot certificates 2>/dev/null \
        | awk '/Domains:/ {for (i=2;i<=NF;i++) print $i}' \
        | sort -u
}

# -------- HTTPS live query (openssl s_client) --------
# cb_discover_https_san host[:port]
cb_discover_https_san() {
    local target="$1"
    command -v openssl >/dev/null 2>&1 || return 0
    local host="${target%%:*}"
    local port="${target##*:}"
    [[ "$host" == "$port" ]] && port=443
    # -servername for SNI, timeout 4s, cert blocks only
    local out
    out=$(echo | timeout 4 openssl s_client -servername "$host" -connect "$host:$port" \
        -showcerts 2>/dev/null | openssl x509 -noout -ext subjectAltName 2>/dev/null)
    [[ -z "$out" ]] && return 0
    # Format: "DNS:example.com, DNS:www.example.com, IP Address:1.2.3.4"
    echo "$out" | grep -oE 'DNS:[^, ]+' | sed 's/^DNS://' | sort -u
}

# -------- Apache VirtualHost --------
cb_discover_apache_domains() {
    local apachectl=""
    for c in apachectl apache2ctl httpd; do
        command -v "$c" >/dev/null 2>&1 && { apachectl="$c"; break; }
    done
    [[ -z "$apachectl" ]] && return 0
    # apachectl -S outputs "namevhost example.com (/etc/apache2/...)"
    # optionally "alias www.example.com"
    "$apachectl" -S 2>/dev/null | awk '
        /namevhost/ {for (i=1;i<=NF;i++) if ($i=="namevhost") print $(i+1)}
        /alias/     {for (i=1;i<=NF;i++) if ($i=="alias")     print $(i+1)}
    ' | grep -vE '^\*|^_default_|^$' | sort -u
}

# -------- nginx server_name --------
cb_discover_nginx_domains() {
    command -v nginx >/dev/null 2>&1 || return 0
    # nginx -T outputs the complete config, including includes
    nginx -T 2>/dev/null \
        | awk '
            /^\s*server_name\s+/ {
                sub(/;.*$/, "")
                sub(/^\s*server_name\s+/, "")
                for (i=1;i<=NF;i++) print $i
            }
        ' | grep -vE '^_$|^$|^localhost$|\*' | sort -u
}

# -------- Tomcat Host name + Alias --------
cb_discover_tomcat_domains() {
    command -v python3 >/dev/null 2>&1 || return 0
    local xml=""
    for p in /etc/tomcat*/server.xml /opt/tomcat*/conf/server.xml /var/lib/tomcat*/conf/server.xml; do
        [[ -f "$p" ]] && { xml="$p"; break; }
    done
    [[ -z "$xml" ]] && return 0
    python3 - "$xml" <<'PY' 2>/dev/null | sort -u
import sys, xml.etree.ElementTree as ET
try:
    t = ET.parse(sys.argv[1])
except Exception:
    sys.exit(0)
for h in t.iter('Host'):
    n = h.get('name')
    if n and n != 'localhost':
        print(n)
    for a in h.iter('Alias'):
        if a.text:
            print(a.text.strip())
PY
}

# -------- Dispatcher --------
cb_discover_webserver_domains() {
    local ws="${1:-auto}"
    case "$ws" in
        apache) cb_discover_apache_domains ;;
        nginx)  cb_discover_nginx_domains ;;
        tomcat) cb_discover_tomcat_domains ;;
        auto|*)
            { cb_discover_apache_domains
              cb_discover_nginx_domains
              cb_discover_tomcat_domains
            } | sort -u
            ;;
    esac
}

# -------- Filter: only domains that point to our server --------
# Args: list of domains (each separately)
# Output: subset whose A/AAAA points to us
cb_filter_points_here() {
    local d
    for d in "$@"; do
        [[ -z "$d" ]] && continue
        # Skip wildcards (cannot verify HTTP-01)
        [[ "$d" == \** ]] && continue
        if cb_domain_points_here "$d"; then
            printf '%s\n' "$d"
        fi
    done
}

# -------- Main collection --------
# cb_discover_all WEBSERVER [--with-localhost]
# Exit: stdout is a list of uniquely obtainable domains (one per line)
# Envs populated for caller:
#   CB_DISC_FROM_CERTBOT      - how many were in certbot
#   CB_DISC_FROM_HTTPS        - how many from live HTTPS
#   CB_DISC_FROM_WEBSERVER    - how many from configuration
#   CB_DISC_SKIPPED_NO_RESOLVE - domains that appeared but do not resolve to us (CSV)
cb_discover_all() {
    local ws="${1:-auto}"
    local -a all=() from_cb from_https from_ws

    # 1) Certbot
    mapfile -t from_cb < <(cb_discover_certbot_domains)
    CB_DISC_FROM_CERTBOT=${#from_cb[@]}

    # 2) Webserver config
    mapfile -t from_ws < <(cb_discover_webserver_domains "$ws")
    CB_DISC_FROM_WEBSERVER=${#from_ws[@]}

    # 3) HTTPS dotaz (jen pokud bezi lokalne nejaky webserver)
    from_https=()
    if command -v ss >/dev/null 2>&1 && ss -tln 2>/dev/null | grep -qE ':443\s'; then
        # kontaktujeme localhost s nekolika SNI pokusy
        local h
        for h in "${from_ws[@]}" localhost; do
            local san
            while IFS= read -r san; do
                [[ -n "$san" ]] && from_https+=("$san")
            done < <(cb_discover_https_san "$h" 2>/dev/null)
            (( ${#from_https[@]} > 0 )) && break
        done
    fi
    CB_DISC_FROM_HTTPS=${#from_https[@]}

    # Union + unique
    all=("${from_cb[@]}" "${from_ws[@]}" "${from_https[@]}")
    local -a uniq=()
    if (( ${#all[@]} > 0 )); then
        mapfile -t uniq < <(printf '%s\n' "${all[@]}" | sort -u | grep -vE '^\s*$')
    fi

    # Filter: actually points here
    local -a good=() bad=()
    local d
    for d in "${uniq[@]}"; do
        [[ "$d" == \** ]] && { bad+=("$d(wildcard)"); continue; }
        if cb_domain_points_here "$d"; then
            good+=("$d")
        else
            bad+=("$d")
        fi
    done

    CB_DISC_SKIPPED_NO_RESOLVE=$(IFS=,; echo "${bad[*]}")

    # In case cb_discover_all is called in a subshell (mapfile < <(...)),
    # we write stats to a file; the caller can retrieve them via cb_discover_load_stats.
    : "${CB_DISC_STATE_FILE:=${TMPDIR:-/tmp}/certberus-disc-$$.env}"
    {
        echo "CB_DISC_FROM_CERTBOT=${CB_DISC_FROM_CERTBOT}"
        echo "CB_DISC_FROM_WEBSERVER=${CB_DISC_FROM_WEBSERVER}"
        echo "CB_DISC_FROM_HTTPS=${CB_DISC_FROM_HTTPS}"
        printf 'CB_DISC_SKIPPED_NO_RESOLVE=%q\n' "$CB_DISC_SKIPPED_NO_RESOLVE"
    } > "$CB_DISC_STATE_FILE" 2>/dev/null || true

    (( ${#good[@]} > 0 )) && printf '%s\n' "${good[@]}"
}

# Loads stats from a previous cb_discover_all call (which may have run in a subshell)
cb_discover_load_stats() {
    : "${CB_DISC_STATE_FILE:=${TMPDIR:-/tmp}/certberus-disc-$$.env}"
    [[ -r "$CB_DISC_STATE_FILE" ]] || return 0
    # shellcheck disable=SC1090
    source "$CB_DISC_STATE_FILE"
}
