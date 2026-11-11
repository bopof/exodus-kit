#!/usr/bin/env bash
# run-monitored.sh -- run a job, then tell your monitor whether it worked.
#
#   run-monitored.sh "<job name>" -- <command> [args...]
#
# Exits with the command's own exit code. A failed heartbeat never turns a good run into a failed one.
#
# Where the heartbeat goes: a push URL, read from (first match wins)
#   1. $CREDENTIALS_DIRECTORY/heartbeat-url    systemd LoadCredential=heartbeat-url:/etc/<x>/<job>.url
#   2. $HEARTBEAT_URL_FILE                     a file holding the URL
#   3. $HEARTBEAT_URL                          the URL itself (avoid: it shows up in `systemctl show`)
# No URL = the command still runs, nothing is pushed. The URL usually contains a token: keep the
# file root-only (chmod 600) and out of git.
#
# Flavours (HEARTBEAT_KIND, default: auto from the URL):
#   kuma           Uptime Kuma push monitor (.../api/push/<token>): status=up|down, msg, ping=duration in ms
#   healthchecks   healthchecks.io and compatible (hc-ping.com/<uuid>, self-hosted): GET <url>/<exit code>
#   plain          GET <url> on success only; your monitor alerts when pings stop
set -uo pipefail

name="${1:?usage: run-monitored.sh <job name> -- <command> [args...]}"; shift
[[ "${1:-}" == "--" ]] && shift
(( $# > 0 )) || { echo "run-monitored: no command given" >&2; exit 2; }

start_ms=$(date +%s%3N)
"$@"
rc=$?
dur_ms=$(( $(date +%s%3N) - start_ms ))

url=""
if [[ -n "${CREDENTIALS_DIRECTORY:-}" && -r "$CREDENTIALS_DIRECTORY/heartbeat-url" ]]; then
    url=$(tr -d '[:space:]' < "$CREDENTIALS_DIRECTORY/heartbeat-url")
elif [[ -n "${HEARTBEAT_URL_FILE:-}" && -r "$HEARTBEAT_URL_FILE" ]]; then
    url=$(tr -d '[:space:]' < "$HEARTBEAT_URL_FILE")
else
    url="${HEARTBEAT_URL:-}"
fi
[[ -n "$url" ]] || exit "$rc"

kind="${HEARTBEAT_KIND:-auto}"
if [[ $kind == auto ]]; then
    case "$url" in
        */api/push/*) kind=kuma ;;
        *hc-ping.com/*|*/ping/*) kind=healthchecks ;;
        *) kind=plain ;;
    esac
fi

push() {
    local tries="${HEARTBEAT_TRIES:-3}" i
    for (( i = 1; i <= tries; i++ )); do
        curl -fsS -m "${HEARTBEAT_TIMEOUT:-30}" -o /dev/null "$@" && return 0
        (( i < tries )) && sleep "${HEARTBEAT_RETRY_SLEEP:-10}"
    done
    return 1
}

case "$kind" in
    kuma)
        status=up; (( rc != 0 )) && status=down
        push -G "${url%%\?*}" --data-urlencode "status=$status" \
            --data-urlencode "msg=$name exit $rc" --data-urlencode "ping=$dur_ms" ;;
    healthchecks)
        push --retry 0 "${url%/}/$rc" ;;
    plain)
        (( rc == 0 )) || exit "$rc"
        push "$url" ;;
    *)
        echo "run-monitored: unknown HEARTBEAT_KIND '$kind'" >&2; false ;;
esac || echo "run-monitored: heartbeat push failed for '$name' ($kind)" >&2

exit "$rc"
