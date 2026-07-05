#!/usr/bin/env bash
# secret-scan.sh — vendored per-project secret gate.
# Canonical source: ~/.claude/templates/githooks/secret-scan.sh (KB.27). Re-vendor with
# secret-guard-install.sh; make edits in the template, never in the copy.
#
# Scans content for real key-shaped strings (a known prefix + a long body) and FAILS (exit 1)
# on any match, so a secret can't reach a commit or a push. Wired as pre-commit (--staged) and
# pre-push (ref range) via core.hooksPath=githooks so it survives a fresh clone. Bypassable only
# with `git commit/push --no-verify` (intentional escape hatch).
#
# Length-anchored patterns ONLY (prefix + {N}-char body) so the scanner can never flag a bare
# prefix or its own pattern list. Defense in depth: the scanner file + the allowlist file are
# excluded from the scan, and the selftest builds its fake key at runtime.
#
# What it catches: key-SHAPED secrets (the prefixes bots scrape GitHub for). It does NOT catch
# passwords, custom/opaque tokens, or base64 blobs — it is a backstop to .gitignore + env vars,
# not a complete DLP.
#
# Allowlist (legit fixtures / example keys) — a repo-root file `.secret-scan-allow`:
#   <ERE>          drop any matched line that matches this regex (e.g. a documented AWS example key)
#   path:<glob>    exclude a git pathspec glob from the scan (e.g. path:**/test/**)
#   # comment      ignored
# Inline: any matched line containing the literal `secret-scan:allow` is dropped.
#
# Modes:
#   secret-scan.sh                pre-push hook: scan added lines in the pushed range (refs on stdin)
#   secret-scan.sh --staged       scan staged content (pre-commit / before a /wrap commit)
#   secret-scan.sh --tracked      detective audit: scan ALL tracked content (kb-doctor / retroactive)
#   secret-scan.sh --selftest     verify it catches a key, ignores the anchored doc, honors the pragma
# Exit: 0 clean, 1 secret found, 2 usage/internal error.
set -uo pipefail

self="$(basename "$0")"
# --- single source of truth: length-anchored secret patterns ------------------
#   ghp_…            GitHub PAT (classic)         github_pat_…  GitHub PAT (fine-grained)
#   AKIA…            AWS access key id            AIza…         Google API key
#   sk-ant-…         Anthropic API key            sk-…          OpenAI / generic secret key
#   xox[baprs]-…     Slack token                  -----BEGIN … PRIVATE KEY-----  PEM private key
PATTERNS='ghp_[A-Za-z0-9]{20}|github_pat_[A-Za-z0-9_]{20}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30}|sk-ant-[A-Za-z0-9_-]{20}|sk-[a-zA-Z0-9]{20}|xox[baprs]-[0-9A-Za-z-]{10}|-----BEGIN [A-Z ]*PRIVATE KEY-----'
ALLOW_FILE=".secret-scan-allow"
root="$(git rev-parse --show-toplevel 2>/dev/null || true)"

# --- allowlist → excludes[] (pathspecs) + an ERE file of line-drops -----------
excludes=( ":(exclude,glob)**/$self" ":(exclude)$ALLOW_FILE" )
allow_rx="$(mktemp 2>/dev/null || echo "/tmp/.ssallow.$$")"
trap 'rm -f "$allow_rx"' EXIT
printf 'secret-scan:allow\n' > "$allow_rx"          # the inline pragma is always honored
if [ -n "$root" ] && [ -f "$root/$ALLOW_FILE" ]; then
    while IFS= read -r _l || [ -n "$_l" ]; do
        _l="$(printf '%s' "$_l" | sed -E 's/[[:space:]]+#.*$//; s/[[:space:]]+$//')"   # strip an inline # comment + trailing ws so an aligned/annotated rule still parses
        case "$_l" in
            ''|\#*)  ;;
            path:*)  excludes+=( ":(exclude,glob)${_l#path:}" ) ;;
            *)       printf '%s\n' "$_l" >> "$allow_rx" ;;
        esac
    done < "$root/$ALLOW_FILE"
fi
apply_allow() { grep -vEf "$allow_rx" || true; }    # drop allowlisted / pragma'd lines

# scan the ADDED lines of a git diff (args = diff args before the pathspecs)
scan_diff() {
    local hits
    hits="$(git "$@" -- . "${excludes[@]}" 2>/dev/null \
        | awk '
            /^\+\+\+ / { f=$0; sub(/^\+\+\+ b\//,"",f); sub(/^\+\+\+ /,"",f); next }
            /^\+/ && !/^\+\+\+/ { l=$0; sub(/^\+/,"",l); print f "\t" l }
          ' \
        | grep -E "$PATTERNS" 2>/dev/null || true)"
    hits="$(printf '%s' "$hits" | apply_allow)"
    [ -n "$hits" ] && { printf '%s\n' "$hits"; return 1; }
    return 0
}

# detective audit: scan ALL tracked content (file:line:content)
scan_tracked() {
    local hits
    hits="$(git grep -InE "$PATTERNS" -- . "${excludes[@]}" 2>/dev/null || true)"
    hits="$(printf '%s' "$hits" | apply_allow)"
    [ -n "$hits" ] && { printf '%s\n' "$hits"; return 1; }
    return 0
}

# pre-push: git passes remote name/url as $1/$2 and the ref updates on stdin:
#   <local ref> <local oid> <remote ref> <remote oid>
scan_prepush() {
    local empty_tree status=0 lref loid rref roid range
    empty_tree="$(git hash-object -t tree /dev/null)"
    while read -r lref loid rref roid; do
        [ -z "${lref:-}" ] && continue
        case "$loid" in *[!0]*) ;; *) continue ;; esac           # branch deletion → nothing to scan
        case "$roid" in
            *[!0]*) range="$roid..$loid" ;;                      # update an existing ref
            *)      range="$empty_tree..$loid" ;;                # brand-new ref → everything it introduces
        esac
        scan_diff diff --unified=0 "$range" || status=1
    done
    return $status
}

selftest() {
    local rc=0 fake doc p
    fake="ghp_$(printf 'a%.0s' {1..20})"                         # built at runtime: literal body never in this file
    doc='docs reference ghp_[A-Za-z0-9]{20} and sk-ant-[A-Za-z0-9_-]{20}'
    if printf '%s\n' "$fake" | grep -qE "$PATTERNS"; then
        echo "selftest: OK   — caught a key-shaped string"
    else
        echo "selftest: FAIL — missed a key-shaped string" >&2; rc=1
    fi
    if printf '%s\n' "$doc" | grep -qE "$PATTERNS"; then
        echo "selftest: FAIL — flagged the anchored pattern doc (self-match)" >&2; rc=1
    else
        echo "selftest: OK   — ignored the anchored pattern doc"
    fi
    p="$(printf '%s secret-scan:allow\n' "$fake" | grep -E "$PATTERNS" || true)"
    p="$(printf '%s' "$p" | apply_allow)"
    if [ -z "$p" ]; then
        echo "selftest: OK   — honored the inline allow pragma"
    else
        echo "selftest: FAIL — inline allow pragma not honored" >&2; rc=1
    fi
    return $rc
}

case "${1:-}" in
    --staged)   scan_diff diff --cached --unified=0 ;;
    --tracked)  scan_tracked ;;
    --selftest) selftest; exit $? ;;
    *)          scan_prepush ;;                                  # pre-push (default)
esac
rc=$?

if [ "$rc" -ne 0 ]; then
    {
        echo ""
        echo "🚫 secret-scan: potential secret detected above — blocked."
        echo "   Remove it. If it is a known fixture/example, add a rule to .secret-scan-allow"
        echo "   (or append \`secret-scan:allow\` to the line). See this script's header."
    } >&2
    exit 1
fi
exit 0
