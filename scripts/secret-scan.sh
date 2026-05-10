#!/usr/bin/env bash
# scripts/secret-scan.sh
# Runs every secret-scanning tool we support against working tree + full git
# history. Exit nonzero on any finding. CI uses .github/workflows/secret-scan.yml;
# this script is for local pre-push checks.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
cd "$REPO"

fail=0
green='\033[0;32m'; red='\033[0;31m'; reset='\033[0m'
ok()   { printf '%b[ OK ]%b %s\n' "$green" "$reset" "$1"; }
err()  { printf '%b[FAIL]%b %s\n' "$red" "$reset" "$1"; fail=1; }

if command -v gitleaks >/dev/null; then
    if gitleaks dir --no-banner --config .gitleaks.toml --redact=0 . 2>&1 | tail -3 \
       | grep -q 'no leaks found'; then
        ok "gitleaks (working tree)"
    else
        err "gitleaks (working tree) - see output above"
    fi
    if gitleaks git --no-banner --config .gitleaks.toml --redact=0 . 2>&1 | tail -3 \
       | grep -q 'no leaks found'; then
        ok "gitleaks (full history)"
    else
        err "gitleaks (full history) - see output above"
    fi
else
    echo "[skip] gitleaks not installed - https://github.com/gitleaks/gitleaks"
fi

if command -v trufflehog >/dev/null; then
    excludes=()
    [[ -f .trufflehog-exclude.txt ]] && excludes=(--exclude-paths .trufflehog-exclude.txt)
    out=$(trufflehog filesystem --no-update "${excludes[@]}" --json . 2>/dev/null \
          | jq -c 'select(.SourceMetadata.Data != null)')
    if [[ -z "$out" ]]; then
        ok "trufflehog (filesystem)"
    else
        err "trufflehog (filesystem)"
        echo "$out" | head -5
    fi
else
    echo "[skip] trufflehog not installed"
fi

if command -v detect-secrets >/dev/null && [[ -f .secrets.baseline ]]; then
    diffout=$(detect-secrets scan --baseline .secrets.baseline \
              --exclude-files '\.git/' --exclude-files '\.gitleaks\.toml$' \
              2>&1 || true)
    if git diff --quiet .secrets.baseline 2>/dev/null; then
        ok "detect-secrets (no new vs baseline)"
    else
        err "detect-secrets - new findings vs .secrets.baseline:"
        git --no-pager diff .secrets.baseline | head -30
    fi
else
    echo "[skip] detect-secrets or .secrets.baseline missing"
fi

if command -v trivy >/dev/null; then
    if trivy fs --scanners secret --quiet --exit-code 1 . 2>&1 | tail -3 \
       | grep -qiE 'no .* detected|^$'; then
        ok "trivy (filesystem secrets)"
    else
        err "trivy (filesystem secrets) - see output above"
    fi
else
    echo "[skip] trivy not installed"
fi

(( fail == 0 )) && ok "ALL clean" || err "secret-scan FAILED"
exit "$fail"
