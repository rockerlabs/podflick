#!/usr/bin/env bash
# secret-scan.sh — vendored per-project secret + personal-data gate.
# Canonical source: ~/.claude/templates/githooks/secret-scan.sh (KB.27). Re-vendor with
# secret-guard-install.sh; make edits in the template, never in the copy.
#
# Scans content and FAILS (exit 1) on a match, so a secret or a piece of personal data can't reach
# a commit or a push. Wired as pre-commit (--staged) and pre-push (ref range) via core.hooksPath=
# githooks so it survives a fresh clone. Bypassable only with `git commit/push --no-verify`.
#
# TWO detector classes (KB.48b):
#   1. key-SHAPED secrets — length-anchored patterns (prefix + {N}-char body), case-SENSITIVE. The
#      prefixes bots scrape GitHub for. Length anchoring means the scanner never flags a bare prefix
#      or its own pattern list.
#   2. personal data — operator-specific literals (real name, device serials, personal drive names,
#      personal emails) loaded case-INSENSITIVELY from a LOCAL, gitignored file, so the literals never
#      enter any repo (see PERSONAL FILE). No broad `/Users/…`-style generic markers: in a KB full of
#      legitimate home paths they only produce false positives — the sensitive literals are precise.
# Both classes are scanned over text diffs AND, crucially, over changed BINARY files by decoding
# UTF-16LE/BE + raw-printable — the PodFlick leak was a real name in UTF-16LE inside an iTunesDB
# fixture, invisible to a plain-text grep.
#
# It does NOT catch passwords, opaque tokens, or base64 blobs — a backstop to .gitignore + env vars,
# not a complete DLP.
#
# PERSONAL FILE (local, never committed) — one regex per line of operator-specific literals:
#   default path: ~/.claude/secret-scan-personal   (override with $SECRET_SCAN_PERSONAL_FILE)
#   lines are EREs (matched case-insensitively), `# comment` and blank lines ignored.
#   Put ONLY things that must never appear in ANY repo (real name, serials, personal drives/emails).
#   Do NOT list the bare home username — it is a legitimate path component in a private KB and would
#   flag every home-path reference. Absent file → only the key patterns run. See secret-scan-personal.example.
#
# Allowlist (legit fixtures / example keys) — a repo-root file `.secret-scan-allow`:
#   <ERE>          drop any matched line that matches this regex (e.g. a documented AWS example key)
#   path:<glob>    exclude a git pathspec glob from the scan (e.g. path:**/test/**)
#   # comment      ignored
# Inline: any matched line containing the literal `secret-scan:allow` is dropped.
#
# Modes:
#   secret-scan.sh                pre-push hook: scan the pushed range (refs on stdin) + its binaries
#   secret-scan.sh --staged       scan staged content (pre-commit / before a /wrap commit) + binaries
#   secret-scan.sh --tracked      detective audit: scan ALL tracked content + binaries (kb-doctor)
#   secret-scan.sh --selftest     verify it catches a key/personal term (incl. UTF-16), honors allows
# Exit: 0 clean, 1 secret/personal-data found, 2 usage/internal error.
set -uo pipefail

self="$(basename "$0")"
# --- class 1: length-anchored secret patterns (case-sensitive) ----------------
#   ghp_…            GitHub PAT (classic)         github_pat_…  GitHub PAT (fine-grained)
#   AKIA…            AWS access key id            AIza…         Google API key
#   sk-ant-…         Anthropic API key            sk-…          OpenAI / generic secret key
#   xox[baprs]-…     Slack token                  -----BEGIN … PRIVATE KEY-----  PEM private key
PATTERNS='ghp_[A-Za-z0-9]{20}|github_pat_[A-Za-z0-9_]{20}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30}|sk-ant-[A-Za-z0-9_-]{20}|sk-[a-zA-Z0-9]{20}|xox[baprs]-[0-9A-Za-z-]{10}|-----BEGIN [A-Z ]*PRIVATE KEY-----'
RX_CS="$PATTERNS"                                # case-sensitive scan set (key-shaped secrets)

ALLOW_FILE=".secret-scan-allow"
PERSONAL_FILE="${SECRET_SCAN_PERSONAL_FILE:-$HOME/.claude/secret-scan-personal}"
root="$(git rev-parse --show-toplevel 2>/dev/null || true)"

# --- class 2: operator-specific literals (case-insensitive) from the local file
RX_CI=""
if [ -f "$PERSONAL_FILE" ]; then
    while IFS= read -r _t || [ -n "$_t" ]; do
        _t="$(printf '%s' "$_t" | sed -E 's/[[:space:]]+#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//')"
        case "$_t" in
            ''|\#*) ;;
            *)      RX_CI="${RX_CI:+$RX_CI|}$_t" ;;
        esac
    done < "$PERSONAL_FILE"
fi
# fail CLOSED on a broken personal regex: a malformed ERE would make every personal grep exit 2,
# which reads as "no match" and would silently disable personal-data detection (a security gate must
# never fail open on its own config). grep exits >=2 only on a bad pattern; 1 (no match) is fine.
if [ -n "$RX_CI" ]; then
    printf '' | grep -iE "$RX_CI" >/dev/null 2>&1
    [ "$?" -ge 2 ] && {
        echo "🚫 secret-scan: invalid regex in $PERSONAL_FILE — personal-data detection would be" >&2
        echo "   silently disabled. Fix the offending line (each line is an ERE). Aborting." >&2
        exit 2
    }
fi

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

# match a text stream on stdin: key patterns case-sensitively, personal literals case-insensitively.
# Buffer once and grep twice — a single shared pipe would let the first grep drain it.
match_stream() {
    local buf; buf="$(cat)"
    { printf '%s\n' "$buf" | grep -E "$RX_CS"
      [ -n "$RX_CI" ] && printf '%s\n' "$buf" | grep -iE "$RX_CI"
    } 2>/dev/null || true
}

# decode a blob's bytes (stdin) via UTF-16LE/BE + raw-printable, then match; prints "path\thit" lines
scan_blob() {
    local label="$1" tmp dec hits
    tmp="$(mktemp 2>/dev/null || echo "/tmp/.ssblob.$$")"
    dec="$(mktemp 2>/dev/null || echo "/tmp/.ssdec.$$")"
    cat > "$tmp"
    # decode each way into one buffer (trailing newline per decoder so end-of-stream matches aren't glued)
    { iconv -f UTF-16LE -t UTF-8//IGNORE "$tmp" 2>/dev/null; echo
      iconv -f UTF-16BE -t UTF-8//IGNORE "$tmp" 2>/dev/null; echo
      LC_ALL=C tr -c '[:print:]\t\n' '\n' < "$tmp"; echo
    } > "$dec"
    hits="$( { grep -aoE "$RX_CS" "$dec" 2>/dev/null
               [ -n "$RX_CI" ] && grep -aoiE "$RX_CI" "$dec" 2>/dev/null
             } | LC_ALL=C sort -u )"
    rm -f "$tmp" "$dec"
    [ -z "$hits" ] && return 0
    hits="$(printf '%s\n' "$hits" | apply_allow)"
    [ -z "$hits" ] && return 0
    printf '%s\n' "$hits" | while IFS= read -r m; do [ -n "$m" ] && printf '%s\t%s\n' "$label" "$m"; done
}

# scan the ADDED lines of a git diff (args = diff args before the pathspecs)
scan_diff() {
    local added hits
    added="$(git "$@" -- . "${excludes[@]}" 2>/dev/null \
        | awk '
            /^\+\+\+ / { f=$0; sub(/^\+\+\+ b\//,"",f); sub(/^\+\+\+ /,"",f); next }
            /^\+/ && !/^\+\+\+/ { l=$0; sub(/^\+/,"",l); print f "\t" l }
          ')"
    hits="$(printf '%s\n' "$added" | match_stream | LC_ALL=C sort -u)"
    hits="$(printf '%s' "$hits" | apply_allow)"
    [ -n "$hits" ] && { printf '%s\n' "$hits"; return 1; }
    return 0
}

# detective audit: scan ALL tracked TEXT content (file:line:content)
scan_tracked() {
    local hits
    hits="$( { git grep -InE "$RX_CS" -- . "${excludes[@]}"
               [ -n "$RX_CI" ] && git grep -IniE "$RX_CI" -- . "${excludes[@]}"
             } 2>/dev/null | LC_ALL=C sort -u || true)"
    hits="$(printf '%s' "$hits" | apply_allow)"
    [ -n "$hits" ] && { printf '%s\n' "$hits"; return 1; }
    return 0
}

# --- binary passes: decode changed/tracked binary blobs and scan (UTF-16-aware) ---
is_binary_file() { ! LC_ALL=C tr -d '\000' < "$1" 2>/dev/null | cmp -s - "$1"; }

scan_binaries_staged() {
    local status=0 f hit
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        hit="$(git show ":$f" 2>/dev/null | scan_blob "$f")"
        [ -n "$hit" ] && { printf '%s\n' "$hit"; status=1; }
    done < <(git -c core.quotePath=false diff --cached --numstat -- . "${excludes[@]}" 2>/dev/null \
             | awk -F'\t' '$1=="-" && $2=="-"{print $3}')
    return $status
}

scan_binaries_tracked() {
    local status=0 f hit
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        [ -f "$f" ] && is_binary_file "$f" || continue
        hit="$(scan_blob "$f" < "$f")"
        [ -n "$hit" ] && { printf '%s\n' "$hit"; status=1; }
    done < <(git -c core.quotePath=false ls-files -- . "${excludes[@]}")
    return $status
}

scan_binaries_range() {                                   # $1 = range, $2 = tip oid
    local status=0 f hit
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        hit="$(git show "$2:$f" 2>/dev/null | scan_blob "$f")"
        [ -n "$hit" ] && { printf '%s\n' "$hit"; status=1; }
    done < <(git -c core.quotePath=false diff --numstat "$1" -- . "${excludes[@]}" 2>/dev/null \
             | awk -F'\t' '$1=="-" && $2=="-"{print $3}')
    return $status
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
        scan_binaries_range "$range" "$loid" || status=1
    done
    return $status
}

selftest() {
    local rc=0 fake doc p hit

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

    # personal literal in plain text (case-insensitive match via a fixture regex)
    hit="$( RX_CI='SeekritPersonName'
            printf 'author: seekritpersonname\n' | match_stream )"
    case "$hit" in
        *seekritpersonname*) echo "selftest: OK   — caught a personal literal in text (case-insensitive)" ;;
        *) echo "selftest: FAIL — missed a personal literal in text" >&2; rc=1 ;;
    esac

    # fail-closed guard: a malformed personal ERE must be detectable (grep exits >=2), not read as no-match
    printf '' | grep -iE 'unbalanced(paren' >/dev/null 2>&1
    if [ "$?" -ge 2 ]; then
        echo "selftest: OK   — a malformed personal regex is detectable (guard fails closed)"
    else
        echo "selftest: FAIL — malformed personal regex not detectable; guard could fail open" >&2; rc=1
    fi

    # binary/UTF-16 pass: a personal literal hidden as UTF-16LE inside a blob is caught
    if command -v iconv >/dev/null 2>&1; then
        hit="$( RX_CI='SeekritPersonName'
                printf 'lead-in SeekritPersonName trail' | iconv -f UTF-8 -t UTF-16LE \
                | scan_blob "fixture.bin" )"
        case "$hit" in
            *SeekritPersonName*) echo "selftest: OK   — caught a personal literal in a UTF-16LE blob" ;;
            *) echo "selftest: FAIL — missed a personal literal in a UTF-16LE blob" >&2; rc=1 ;;
        esac
    else
        echo "selftest: WARN — iconv absent; UTF-16 binary pass is a no-op on this host" >&2
    fi

    return $rc
}

rc=0
case "${1:-}" in
    --staged)   scan_diff diff --cached --unified=0 || rc=1
                scan_binaries_staged || rc=1 ;;
    --tracked)  scan_tracked || rc=1
                scan_binaries_tracked || rc=1 ;;
    --selftest) selftest; exit $? ;;
    *)          scan_prepush || rc=1 ;;                          # pre-push (default)
esac

if [ "$rc" -ne 0 ]; then
    {
        echo ""
        echo "🚫 secret-scan: potential secret or personal data detected above — blocked."
        echo "   Remove it. If it is a known fixture/example, add a rule to .secret-scan-allow"
        echo "   (or append \`secret-scan:allow\` to the line). Operator-specific literals live in the"
        echo "   local, gitignored \$SECRET_SCAN_PERSONAL_FILE. See this script's header."
    } >&2
    exit 1
fi
exit 0
