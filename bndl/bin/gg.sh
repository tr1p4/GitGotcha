#! /usr/bin/env modernish
#! use safe -k
#! use sys/cmd/harden
#! use sys/cmd/mapr
#! use var/arith

# Harden external commands: die on unexpected failure instead of
# silently continuing. curl/jq/sort failures now kill the program.
harden -p curl
harden -p jq
harden -p sort

usage() {
    putln "Usage: $ME -u <username> [-t <token>] [-n]" >&2
    putln "       GITHUB_TOKEN=<token> $ME -u <username> [-n]" >&2
    putln "" >&2
    putln "Options:" >&2
    putln "  -u <username>   GitHub username to search commits for (required)" >&2
    putln "  -t <token>      GitHub token (exposes it via ps(1); prefer GITHUB_TOKEN)" >&2
    putln "  -n              Include @users.noreply.github.com proxy addresses" >&2
    putln "" >&2
    putln "Note: -t <token> exposes the token via ps(1). Prefer GITHUB_TOKEN" >&2
    putln "      or the interactive prompt." >&2
    exit 2
}

# --- Manual option parsing (no subshell, no eval) ---
unset -v opt_t opt_u opt_n
while case ${1-} in
    ( -[!-]?* )
        # Split a cluster of combined short options into individual ones.
        # e.g. -tvalue  →  -t value  (rest of string becomes the optarg)
        opt__o=$1
        shift
        while opt__o=${opt__o#?} && not str empty "${opt__o}"; do
            opt__a=-${opt__o%"${opt__o#?}"} # "
            push opt__a
            case ${opt__o} in
            ( [tu]* )
                # Option takes an argument: rest of string is the optarg.
                opt__a=${opt__o#?}
                not str empty "${opt__a}" && push opt__a && break ;;
            esac
        done
        while pop opt__a; do
            set -- "${opt__a}" "$@"
        done
        unset -v opt__o opt__a
        continue ;;
    ( -u )
        let "$# > 1" || die "$ME: $1: option requires argument"
        opt_u=$2
        shift ;;
    ( -t )
        let "$# > 1" || die "$ME: $1: option requires argument"
        opt_t=$2
        shift ;;
    ( -n )
        opt_n=1 ;;
    ( -- )  shift; break ;;
    ( -* )  die "$ME: invalid option: $1" ;;
    ( * )   break ;;
    esac
do
    shift
done

isset opt_u || usage
USERNAME=$opt_u

# Validate username: GitHub usernames are restricted to alphanumerics
# and hyphens. This doubles as URL-safety since none of these
# characters require encoding.
case $USERNAME in
( '' )              die "Error: username must not be empty." ;;
( *[!a-zA-Z0-9-]* ) die "Error: invalid GitHub username '$USERNAME'." ;;
esac

# Resolve the token: prefer -t, then GITHUB_TOKEN env var, then prompt.
if isset opt_t; then
    TOKEN=$opt_t
elif isset GITHUB_TOKEN && not str empty "$GITHUB_TOKEN"; then
    TOKEN=$GITHUB_TOKEN
else
    put 'Please enter your GitHub token: ' >&2
    read -r TOKEN || die "failed to read token (EOF or read error)"
fi
not str empty "$TOKEN" || die "Error: GitHub token is required."

readonly URL="https://api.github.com/search/commits?q=author:${USERNAME}&sort=author-date&order=desc&per_page=100"
readonly AUTH="Authorization: token ${TOKEN}"
# +json suffix is required by modern GitHub API; the bare
# 'cloak-preview' media type without it can return 200 with empty items.
readonly ACCEPT="Accept: application/vnd.github.cloak-preview+json"

# In-shell accumulator: newline-delimited with sentinel newlines at
# both ends so 'str in' substring checks can't false-match on partial
# addresses. 'skipped' counts dropped @users.noreply.github.com
# addresses; 'total' counts unique emails kept (for the summary line).
emails=$CCn
total=0
skipped=0

collect() {
    for rec do
        email=${rec%%"$CCt"*}
        # Skip records with no email (jq @tsv renders null as empty).
        str empty "$email" && continue
        # Skip GitHub's redacted proxy addresses unless -n was given.
        # Anchored match is stricter than the old 'str in' substring check.
        if not isset opt_n; then
            case $email in
            ( *@users.noreply.github.com ) inc skipped; continue ;;
            esac
        fi
        if not str in "$emails" "$CCn$email$CCn"; then
            emails=$emails$email$CCn
            inc total
        fi
    done
}

page=1
while :; do
    body=$(curl -sS --connect-timeout 10 --max-time 60 \
        -w '\n%{http_code}' -H "$AUTH" -H "$ACCEPT" \
        "${URL}&page=${page}")
    # last line = status code; rest = JSON body
    code=${body##*$CCn}
    json=${body%"$CCn$code"}

    case $code in
    ( 200 ) ;;
    ( 403 )
        # 403 is overloaded: rate limit, scope, or endpoint block.
        # Inspect the message rather than assuming rate limit.
        msg=$(putln "$json" | jq -r '.message // empty')
        case $msg in
        ( *rate*limit* ) putln "Rate limit exceeded. Try again later." >&2 ;;
        ( '' )           putln "403 from GitHub (no message body)." >&2 ;;
        ( * )            putln "403 from GitHub: $msg" >&2 ;;
        esac
        break ;;
    ( 422 )
        # GitHub returns 422 once you exceed the 1000-result search cap.
        putln "Reached GitHub's search result limit (1000). Stopping." >&2
        break ;;
    ( * )   die "Error: HTTP $code" ;;
    esac

    count=$(putln "$json" | jq '.items | length')
    if let 'count == 0'; then
        break
    fi

    # Surface server-side truncation explicitly.
    incomplete=$(putln "$json" | jq -r '.incomplete_results // false')
    if str eq "$incomplete" 'true'; then
        putln "Warning: GitHub marked these results as incomplete." >&2
    fi

    # Two-step feed: capture the TSV in a variable with a plain
    # pipeline, then redirect it into mapr via a here-document. This
    # keeps mapr (and thus 'collect') in the MAIN shell so the
    # accumulator persists. Feeding mapr from a pipeline element would
    # run it in a subshell and silently discard every write 'collect'
    # makes to 'emails' and 'skipped'.
    records=$(putln "$json" \
        | jq -r '.items[] | [.commit.author.email, .repository.full_name] | @tsv')
    mapr collect <<HEREDOCEND
$records
HEREDOCEND

    inc page
done

# One-line stderr summary so success is visible without polluting the
# clean stdout email list. (The zero-results case is handled below.)
if let 'total > 0'; then
    putln "$ME: $total unique emails found ($skipped proxy addresses skipped)." >&2
fi

# Drop leading sentinel newline, then sort -u defensively. The
# in-shell dedup is already correct, but the extra cost is negligible
# and it survives any future regression in the accumulator.
# If nothing survived the filter, say so on stderr (with a hint about
# -n if any addresses were skipped as noreply proxies).
if str empty "${emails#"$CCn"}"; then
    if let 'skipped > 0'; then
        putln "$ME: no emails found; ${skipped} @users.noreply.github.com" >&2
        putln "      proxy address(es) were skipped. Re-run with -n to include them." >&2
    else
        putln "$ME: no emails found for '$USERNAME'." >&2
        putln "      Verify the username and the token's 'repo' scope." >&2
    fi
    exit 1
fi
put "${emails#"$CCn"}" | sort -u

