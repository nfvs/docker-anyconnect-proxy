#!/bin/bash

set -euo pipefail

COOKIE_FILE=/run/anyconnect/cookie
TUNNEL_DEVICE=/sys/class/net/tun0
# restart-openconnect.sh creates this file before it stops openconnect, to ask for a new start.
export RESTART_MARKER=/run/openconnect-restart
# openconnect sets no timeout on the TLS handshake or the CONNECT request, so a gateway that never answers would
# stall a start for good.
START_TIMEOUT=10
RETRY_INTERVAL=10
# openconnect exits with this status when the gateway rejects the cookie.
REJECTED_COOKIE_STATUS=2

openconnect_pid=
stopping=0

mkdir -p /dev/net
[[ -e /dev/net/tun ]] || mknod /dev/net/tun c 10 200

# Started here so that it keeps running across openconnect restarts without holding the tunnel device open.
REQUIRE_AUTH=false /socks5 &

# Reads the saved session again, so that each start uses the current cookie file.
read_session() {
    if [[ ! -s "$COOKIE_FILE" ]]; then
        echo "Missing or empty cookie file $COOKIE_FILE; run service.sh connect on the host." >&2
        exit 1
    fi

    # shellcheck source=/dev/null
    source "$COOKIE_FILE"

    if [[ -z "${ANYCONNECT_COOKIE:-}" ]]; then
        echo "No cookie in $COOKIE_FILE; run service.sh logout, then service.sh connect on the host." >&2
        exit 1
    fi

    local target="${ANYCONNECT_CONNECT_URL:-${ANYCONNECT_HOST:-${ANYCONNECT_SERVER:-}}}"
    if [[ -z "$target" ]]; then
        echo "No VPN server in $COOKIE_FILE; run service.sh logout, then service.sh connect on the host." >&2
        exit 1
    fi

    openconnect_args=(--cookie-on-stdin --useragent "${ANYCONNECT_USERAGENT:?is not set}")
    if [[ -n "${ANYCONNECT_CERT:-}" ]]; then
        openconnect_args+=(--servercert "$ANYCONNECT_CERT")
    fi
    if [[ -n "${ANYCONNECT_RESOLVE:-}" ]]; then
        openconnect_args+=(--resolve "$ANYCONNECT_RESOLVE")
    fi
    openconnect_args+=("$target")
}

# True while openconnect runs without a tunnel and nobody asked the container to stop.
connecting() {
    [[ ! -e "$TUNNEL_DEVICE" ]] && ((!stopping)) && kill -0 "$openconnect_pid" 2>/dev/null
}

restart_if_stalled() {
    local waited=0

    while connecting; do
        if ((waited++ == START_TIMEOUT)); then
            echo "openconnect did not connect within ${START_TIMEOUT}s; starting a new one." >&2
            touch "$RESTART_MARKER"
            kill -HUP "$openconnect_pid" 2>/dev/null || true
            return
        fi
        sleep 1
    done
}

wait_for_openconnect() {
    local status

    while :; do
        status=0
        wait "$openconnect_pid" || status=$?
        # A trapped signal ends wait early, while openconnect still runs.
        kill -0 "$openconnect_pid" 2>/dev/null || return "$status"
    done
}

# service.sh stops the container with SIGHUP to keep the session or SIGTERM to end it, so openconnect must get the same
# signal.
# shellcheck disable=SC2329 # The traps below call it.
stop_openconnect() {
    stopping=1
    kill -s "$1" "$openconnect_pid" 2>/dev/null || true
}

trap 'stop_openconnect HUP' HUP
trap 'stop_openconnect INT' INT
trap 'stop_openconnect TERM' TERM

restarted=0
status=0
while :; do
    rm -f "$RESTART_MARKER"
    read_session
    # No openconnect runs here to forward a stop signal to, so check for one before starting it.
    if ((stopping)); then
        break
    fi
    openconnect "${openconnect_args[@]}" <<<"$ANYCONNECT_COOKIE" &
    openconnect_pid=$!
    restart_if_stalled
    connected=0
    if [[ -e "$TUNNEL_DEVICE" ]]; then
        connected=1
    fi
    status=0
    wait_for_openconnect || status=$?

    if ((stopping)); then
        break
    elif [[ -e "$RESTART_MARKER" ]]; then
        restarted=1
    elif ((restarted && !connected && status != REJECTED_COOKIE_STATUS)); then
        # After the Mac wakes, the network can be unreachable for a while.
        echo "openconnect exited with status $status before it connected; trying again in ${RETRY_INTERVAL}s." >&2
        sleep "$RETRY_INTERVAL" &
        # Unlike a sleep in the foreground, wait returns as soon as a trapped signal arrives.
        wait $! || true
    else
        break
    fi
done
exit "$status"
