#!/usr/bin/env bash

set -euo pipefail

script_path="${BASH_SOURCE[0]}"
while [[ -L "$script_path" ]]; do
    link_dir="$(cd -P "$(dirname "$script_path")" && pwd)"
    script_path="$(readlink "$script_path")"
    [[ "$script_path" == /* ]] || script_path="$link_dir/$script_path"
done

CODE_PATH="$(cd -P "$(dirname "$script_path")" && pwd)"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/anyconnect-proxy"
COOKIE_PATH="$STATE_DIR/cookie"

NAME=anyconnect
IMAGE=anyconnect:latest
PROXY_PORT=1080
# The VPN uses about 60 MB and one core; Apple's default of 4 CPUs and 1 GB inflates the VM on the Mac.
CONTAINER_CPUS=2
CONTAINER_MEMORY=512M
# Apple's default MTU of 1280 leaves the tunnel an MTU of 1166.
NETWORK_MTU=1500
# Apple's kernel has no vhost-net, so openconnect drains DTLS slowly; the default buffer drops bursts.
UDP_RECEIVE_BUFFER_BYTES=$((4 * 1024 * 1024))
# Long enough for openconnect to log the session out on SIGTERM.
STOP_TIMEOUT=20
READY_TIMEOUT="${ANYCONNECT_READY_TIMEOUT:-60}"
TRAFFIC_TIMEOUT="${ANYCONNECT_TRAFFIC_TIMEOUT:-10}"
DNS_QUERY_TIMEOUT=3
POLL_INTERVAL="${ANYCONNECT_POLL_INTERVAL:-1}"
TIMED_OUT_STATUS=2

DEFAULT_USERAGENT="AnyConnect-compatible OpenConnect VPN Agent"
EMPTY_PIN="pin-sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
VPN_RESOLV_CONF=/etc/resolv.vpn.conf
TUNNEL_CHECK="ip link show tun0 | grep -q '[<,]UP[,>]' && netstat -ltn | grep -q ':$PROXY_PORT '"
# Asks each of the VPN's nameservers, past the DNS cache, for its own name until one replies. Busybox prints "Server:"
# only once a reply arrives, so any reply, even NXDOMAIN, proves that the tunnel carries traffic.
TRAFFIC_CHECK="for server in \$(awk '/^nameserver/ { print \$2 }' $VPN_RESOLV_CONF); do \
    timeout $DNS_QUERY_TIMEOUT nslookup \$server \$server | grep -q '^Server:' && exit 0; done; exit 1"
REJECTED_SESSION="Cookie was rejected by server|401 Unauthorized|None of the [0-9]+ fingerprint\(s\) specified via --servercert match"

die() {
    echo "$*" >&2
    exit 1
}

load_config() {
    if [[ -f "$CODE_PATH/.env" ]]; then
        # shellcheck source=/dev/null
        source "$CODE_PATH/.env"
    fi

    CONFIGURED_SERVER="${ANYCONNECT_SERVER:-}"
    CONFIGURED_CERT="${ANYCONNECT_CERT:-}"
    CONFIGURED_RESOLVE="${ANYCONNECT_RESOLVE:-}"
    CONFIGURED_HOST="${ANYCONNECT_HOST:-}"
    CONFIGURED_CONNECT_URL="${ANYCONNECT_CONNECT_URL:-}"
    USERAGENT="${ANYCONNECT_USERAGENT:-$DEFAULT_USERAGENT}"

    if [[ "$CONFIGURED_SERVER" != */SAML-EXT ]]; then
        die "Set ANYCONNECT_SERVER in $CODE_PATH/.env to a URL ending in /SAML-EXT."
    fi
}

container_state() {
    container inspect "$NAME" 2>/dev/null | sed -n 's/.*"state" *: *"\([a-z]*\)".*/\1/p' || true
}

tunnel_up() {
    container exec "$NAME" sh -c "$TUNNEL_CHECK" >/dev/null 2>&1
}

carries_traffic() {
    container exec "$NAME" sh -c "$TRAFFIC_CHECK" >/dev/null 2>&1
}

# Prints absent, the state of a container that is not running, tunnel_down, no_traffic or ready.
vpn_health() {
    local state
    state="$(container_state)"

    if [[ "$state" != running ]]; then
        echo "${state:-absent}"
    elif ! tunnel_up; then
        echo tunnel_down
    elif ! carries_traffic; then
        echo no_traffic
    else
        echo ready
    fi
}

stop_container() {
    local signal="$1" state
    state="$(container_state)"

    if [[ "$state" == running ]]; then
        echo "Stopping the VPN container with $signal..."
        container stop --signal "$signal" --time "$STOP_TIMEOUT" "$NAME" >/dev/null
    fi
    if [[ -n "$state" ]]; then
        container delete "$NAME" >/dev/null
    fi
}

# 'container system status' can report the service as not running while it answers requests.
system_running() {
    container ls >/dev/null 2>&1
}

ensure_system() {
    system_running || container system start
}

build_image() {
    local output
    container build -t "$IMAGE" -f "$CODE_PATH/Dockerfile" "$CODE_PATH"
    # The builder VM otherwise stays up holding over 1 GB; the next build restarts it.
    output="$(container builder stop 2>&1)" || echo "Could not stop the image builder: $output" >&2
}

ensure_image() {
    container image inspect "$IMAGE" >/dev/null 2>&1 || build_image
}

# Reads the cache in a subshell so that cached values never reach authentication.
use_cached_cookie() {
    local cached_server

    [[ -s "$COOKIE_PATH" ]] || return 1
    cached_server="$(
        # shellcheck source=/dev/null
        source "$COOKIE_PATH"
        [[ -n "${ANYCONNECT_COOKIE:-}" ]] && printf '%s' "${ANYCONNECT_SERVER:-}"
    )" || return 1

    if [[ "$cached_server" != "$CONFIGURED_SERVER" ]]; then
        echo "Ignoring the cached cookie for $cached_server; the configured server is $CONFIGURED_SERVER."
        return 1
    fi
    echo "Using the cached cookie."
}

# Prints the last NAME='value' assignment in the openconnect output, or the fallback.
auth_value() {
    local name="$1" output="$2" fallback="${3:-}" value
    value="$(printf '%s\n' "$output" | sed -n "s/^$name='\(.*\)'\$/\1/p" | tail -n 1)"
    printf '%s' "${value:-$fallback}"
}

save_session() {
    local cookie="$1" connect_url="$2" host="$3" pin="$4" resolve="$5" tmp_path

    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    tmp_path="$(mktemp "$COOKIE_PATH.XXXXXX")"
    chmod 600 "$tmp_path"
    printf 'export %s=%q\n' \
        ANYCONNECT_SERVER "$CONFIGURED_SERVER" \
        ANYCONNECT_CONNECT_URL "$connect_url" \
        ANYCONNECT_HOST "$host" \
        ANYCONNECT_CERT "$pin" \
        ANYCONNECT_RESOLVE "$resolve" \
        ANYCONNECT_COOKIE "$cookie" >"$tmp_path"
    mv "$tmp_path" "$COOKIE_PATH"
}

authenticate() {
    local output cookie pin
    local args=(--useragent "$USERAGENT" --authenticate)

    if [[ -n "$CONFIGURED_CERT" ]]; then
        args+=(--servercert "$CONFIGURED_CERT")
    fi
    if [[ -n "$CONFIGURED_RESOLVE" ]]; then
        args+=(--resolve "$CONFIGURED_RESOLVE")
    fi

    echo "Logging in to $CONFIGURED_SERVER..."
    output="$(openconnect "${args[@]}" "$CONFIGURED_SERVER")" || die "Login failed."

    cookie="$(auth_value COOKIE "$output")"
    [[ -n "$cookie" ]] || die "Login returned no cookie."

    pin="$(auth_value FINGERPRINT "$output")"
    if [[ -z "$pin" || "$pin" == "$EMPTY_PIN" ]]; then
        pin="$CONFIGURED_CERT"
    fi

    save_session "$cookie" \
        "$(auth_value CONNECT_URL "$output" "$CONFIGURED_CONNECT_URL")" \
        "$(auth_value HOST "$output" "$CONFIGURED_HOST")" \
        "$pin" \
        "$(auth_value RESOLVE "$output" "$CONFIGURED_RESOLVE")"
}

run_container() {
    container run -d --name "$NAME" \
        --cpus "$CONTAINER_CPUS" --memory "$CONTAINER_MEMORY" \
        --cap-add NET_ADMIN \
        --network "default,mtu=$NETWORK_MTU" \
        --kernel-arg "sysctl.net.core.rmem_default=$UDP_RECEIVE_BUFFER_BYTES" \
        --mount "type=bind,source=$STATE_DIR,target=/run/anyconnect,readonly" \
        -p "127.0.0.1:$PROXY_PORT:$PROXY_PORT" \
        --env "PROXY_PORT=$PROXY_PORT" \
        --env "VPN_RESOLV_CONF=$VPN_RESOLV_CONF" \
        --env "ANYCONNECT_USERAGENT=$USERAGENT" \
        "$IMAGE" >/dev/null
}

# Polls the check until it passes. Fails with 1 if the container exits, or prints the message and fails with
# TIMED_OUT_STATUS once the timeout runs out.
wait_for() {
    local check="$1" deadline=$((SECONDS + $2)) message="$3"

    until "$check"; do
        if [[ "$(container_state)" != running ]]; then
            echo "The VPN container exited." >&2
            return 1
        fi
        if ((SECONDS >= deadline)); then
            echo "$message" >&2
            return "$TIMED_OUT_STATUS"
        fi
        sleep "$POLL_INTERVAL"
    done
}

# Fails with TIMED_OUT_STATUS only if the tunnel came up but carried no traffic in time.
wait_until_ready() {
    wait_for tunnel_up "$READY_TIMEOUT" "The VPN was not ready after ${READY_TIMEOUT}s." || return 1
    wait_for carries_traffic "$TRAFFIC_TIMEOUT" "The tunnel carried no traffic for ${TRAFFIC_TIMEOUT}s."
}

# Fails like wait_until_ready. Callers test the result, which turns off errexit here, so failures are checked
# explicitly.
start_container() {
    local result=0

    stop_container SIGHUP
    echo "Starting the VPN container..."
    run_container || return 1

    wait_until_ready || result=$?
    if ((result == 0)); then
        echo "Connected. SOCKS5 proxy: socks5h://127.0.0.1:$PROXY_PORT"
        return 0
    fi
    echo "Container logs:" >&2
    container logs "$NAME" >&2 || true
    return "$result"
}

session_rejected() {
    local logs
    logs="$(container logs "$NAME" 2>&1)" || return 1
    grep -Eq "$REJECTED_SESSION" <<<"$logs"
}

connect() {
    local from_cache=0 result=0

    if [[ "$(vpn_health)" == ready ]]; then
        echo "Already connected; nothing to do."
        return 0
    fi

    load_config
    ensure_system
    ensure_image

    if use_cached_cookie; then
        from_cache=1
    else
        authenticate
    fi

    start_container || result=$?
    if ((result == 0)); then
        return 0
    elif ((!from_cache)); then
        return 1
    elif ((result == TIMED_OUT_STATUS)); then
        echo "The cached session carries no traffic; logging in again."
    elif session_rejected; then
        echo "The gateway rejected the cached session; logging in again."
    else
        return 1
    fi

    rm -f "$COOKIE_PATH"
    authenticate
    start_container || return 1
}

disconnect() {
    stop_container SIGHUP
    echo "Disconnected; the session is kept."
}

logout() {
    local message="The VPN was not running; no cached cookie remains."

    if [[ "$(container_state)" == running ]]; then
        message="Logged out; no cached cookie remains."
    fi
    stop_container SIGTERM
    rm -f "$COOKIE_PATH"
    echo "$message"
}

status() {
    local health

    if ! system_running; then
        echo "The container system service is not running."
        return 0
    fi

    health="$(vpn_health)"
    case "$health" in
    absent) echo "$NAME: no container" ;;
    tunnel_down) echo "$NAME: running, tunnel not up" ;;
    no_traffic) echo "$NAME: running, tunnel up but carries no traffic" ;;
    ready) echo "$NAME: running, tunnel ready" ;;
    *) echo "$NAME: $health" ;;
    esac
}

usage() {
    cat <<EOF
Usage: $(basename "$0") <command>

Commands:
  connect, up, start, on       Connect; reuse the cached session or log in. No-op if connected.
  disconnect, down, stop, off  Disconnect and keep the session.
  reconnect, restart           Disconnect, then connect, without rebuilding the image.
  rebuild                      Rebuild the image, then reconnect.
  logout                       End the session if connected and delete the cached cookie.
  status                       Show the container state and whether the tunnel carries traffic.
  logs [args]                  Show the container logs; args go to 'container logs'.
  help, -h, --help             Show this help.
EOF
}

action="${1:-help}"
shift || true

case "$action" in
connect | up | start | on)
    connect
    ;;
disconnect | down | stop | off)
    disconnect
    ;;
reconnect | restart)
    load_config
    disconnect
    connect
    ;;
rebuild)
    load_config
    ensure_system
    build_image
    disconnect
    connect
    ;;
logout)
    logout
    ;;
status)
    status
    ;;
logs)
    container logs "$@" "$NAME"
    ;;
help | -h | --help)
    usage
    ;;
*)
    usage >&2
    exit 2
    ;;
esac
