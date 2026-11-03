#!/usr/bin/env bash

set -e

SCRIPT_PATH="${BASH_SOURCE[0]}"
while [[ -L "$SCRIPT_PATH" ]]; do
    SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_PATH")" && pwd)"
    SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"
    [[ "$SCRIPT_PATH" != /* ]] && SCRIPT_PATH="${SCRIPT_DIR}/${SCRIPT_PATH}"
done

CODE_PATH="$(cd -P "$(dirname "$SCRIPT_PATH")" && pwd)"
STATE_DIR="${CODE_PATH}/.state"
COOKIE_PATH="${STATE_DIR}/cookie"

if [ -f "$CODE_PATH/.env" ]; then
    source "$CODE_PATH/.env"
fi

ANYCONNECT_USERAGENT="${ANYCONNECT_USERAGENT:-AnyConnect-compatible OpenConnect VPN Agent}"

readonly CONFIGURED_SERVER="${ANYCONNECT_SERVER:-}"
readonly CONFIGURED_CONNECT_URL="${ANYCONNECT_CONNECT_URL:-}"
readonly CONFIGURED_HOST="${ANYCONNECT_HOST:-}"
readonly CONFIGURED_CERT="${ANYCONNECT_CERT:-}"
readonly CONFIGURED_RESOLVE="${ANYCONNECT_RESOLVE:-}"

authenticate() {
    if [[ "${ANYCONNECT_SERVER}" == *"/SAML-EXT" ]]; then
        saml_flow
    else
        echo "Unsupported server: ${ANYCONNECT_SERVER}; only SAML-EXT is supported"
        exit 1
    fi
}

auth_var() {
    local name="$1"

    sed -n "s/^${name}='\\(.*\\)'$/\\1/p" | tail -n 1
}

parse_auth_output() {
    local output="$1"
    local cookie cert resolve host connect_url

    cookie=$(printf '%s\n' "$output" | auth_var COOKIE)
    if [[ -z "$cookie" ]]; then
        return 1
    fi

    cert=$(printf '%s\n' "$output" | auth_var FINGERPRINT)
    resolve=$(printf '%s\n' "$output" | auth_var RESOLVE)
    host=$(printf '%s\n' "$output" | auth_var HOST)
    connect_url=$(printf '%s\n' "$output" | auth_var CONNECT_URL)

    ANYCONNECT_COOKIE="$cookie"
    [[ -n "$cert" && "$cert" != "pin-sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" ]] && ANYCONNECT_CERT="$cert"
    [[ -n "$resolve" ]] && ANYCONNECT_RESOLVE="$resolve"
    [[ -n "$host" ]] && ANYCONNECT_HOST="$host"
    [[ -n "$connect_url" ]] && ANYCONNECT_CONNECT_URL="$connect_url"

    return 0
}

write_cookie_file() {
    local tmp_path

    mkdir -p "${STATE_DIR}" || return $?
    chmod 700 "${STATE_DIR}" || return $?

    tmp_path="$(umask 077 && mktemp "${COOKIE_PATH}.XXXXXX")" || return $?
    printf 'export %s=%q\n' \
        ANYCONNECT_SERVER "$ANYCONNECT_SERVER" \
        ANYCONNECT_CONNECT_URL "${ANYCONNECT_CONNECT_URL:-}" \
        ANYCONNECT_HOST "${ANYCONNECT_HOST:-}" \
        ANYCONNECT_CERT "${ANYCONNECT_CERT:-}" \
        ANYCONNECT_RESOLVE "${ANYCONNECT_RESOLVE:-}" \
        ANYCONNECT_COOKIE "$ANYCONNECT_COOKIE" >"${tmp_path}" || return $?

    chmod 600 "${tmp_path}" || return $?
    mv "${tmp_path}" "${COOKIE_PATH}"
}

compose_up() {
    local status

    mkdir -p "${STATE_DIR}"
    chmod 700 "${STATE_DIR}"

    COMPOSE_START_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    set +e
    (cd "$CODE_PATH" && "${DOCKER_COMPOSE[@]}" up "$@")
    status=$?
    docker logs --since "$COMPOSE_START_TIME" --tail 80 anyconnect_vpn || true
    set -e

    return "$status"
}

stack_ready() {
    local proxy_state vpn_state

    vpn_state=$(docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' anyconnect_vpn 2>/dev/null) || return 1
    proxy_state=$(docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' anyconnect_proxy 2>/dev/null) || return 1

    [[ "$vpn_state" == "running healthy" && "$proxy_state" == "running healthy" ]]
}

start_vpn() {
    local failure_reason

    authenticate || return $?

    if compose_up "$@"; then
        return 0
    fi

    if [[ "${ANYCONNECT_COOKIE_FROM_CACHE:-}" == "1" ]] && failure_reason=$(vpn_cached_auth_failure); then
        echo "Cached ${failure_reason}; re-authenticating..."
        rm -f "${COOKIE_PATH}"
        ANYCONNECT_COOKIE=""
        authenticate || return $?
        # Recreate namespace-sharing services after cached authentication fails.
        # Restarting only the VPN can leave the proxy attached to the old network
        # namespace and permanently unhealthy.
        compose_up --force-recreate "$@"
        return $?
    fi

    return 1
}

vpn_cached_auth_failure() {
    local logs

    logs=$(docker logs --since "$COMPOSE_START_TIME" --tail 120 anyconnect_vpn 2>&1) || return 1
    if printf '%s\n' "$logs" | grep -Eq "None of the [0-9]+ fingerprint\(s\) specified via --servercert match server's certificate"; then
        echo "certificate pin no longer matches the VPN gateway"
    elif printf '%s\n' "$logs" | grep -Eq "Cookie was rejected by server|401 Unauthorized"; then
        echo "cookie was rejected by the VPN gateway"
    else
        return 1
    fi
}

saml_flow() {
    local output
    local openconnect_args
    local cached_server

    ANYCONNECT_COOKIE_FROM_CACHE=0

    if [[ -s "$COOKIE_PATH" ]]; then
        echo "Using existing cookie..."
        # shellcheck disable=SC1090
        source "${COOKIE_PATH}"
    fi

    if [[ -n "${ANYCONNECT_COOKIE:-}" ]]; then
        cached_server="${ANYCONNECT_SERVER:-}"

        if [[ -n "$cached_server" && "$cached_server" != "$CONFIGURED_SERVER" ]]; then
            echo "Ignoring existing cookie for ${cached_server}; configured server is ${CONFIGURED_SERVER}."
            ANYCONNECT_COOKIE=""
        else
            ANYCONNECT_COOKIE_FROM_CACHE=1
        fi
    fi

    if [[ -z "${ANYCONNECT_COOKIE}" ]]; then
        ANYCONNECT_SERVER="$CONFIGURED_SERVER"
        ANYCONNECT_CONNECT_URL="$CONFIGURED_CONNECT_URL"
        ANYCONNECT_HOST="$CONFIGURED_HOST"
        ANYCONNECT_CERT="$CONFIGURED_CERT"
        ANYCONNECT_RESOLVE="$CONFIGURED_RESOLVE"

        echo "Connecting to ${ANYCONNECT_SERVER}..."
        openconnect_args=(
            --useragent="${ANYCONNECT_USERAGENT}"
            --authenticate
        )

        [[ -n "${ANYCONNECT_RESOLVE:-}" ]] && openconnect_args+=(--resolve "${ANYCONNECT_RESOLVE}")
        [[ -n "${ANYCONNECT_CERT:-}" ]] && openconnect_args+=(--servercert "${ANYCONNECT_CERT}")

        output=$(openconnect "${openconnect_args[@]}" "${ANYCONNECT_SERVER}") || return $?
        if ! parse_auth_output "$output"; then
            echo "Failed to parse authentication cookie from openconnect output."
            exit 1
        fi

        write_cookie_file || return $?
    fi

    export ANYCONNECT_SERVER
    export ANYCONNECT_PUBLIC_KEY
    export ANYCONNECT_USER
    export ANYCONNECT_USERAGENT
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [up|start|on|off|restart|rebuild|clear|clean|status|help|docker-compose args...]

Commands:
  up, start, on  No-op if running; otherwise start with the cached cookie
  off            Stop and remove the stack, keeping the cookie
  restart        Recreate the stack with the cached cookie, without rebuilding
  rebuild        Build images and recreate the stack
  clear          Delete the cookie, authenticate, then start the stack
  clean          Stop and remove the stack, then delete the cookie
  status         Show stack status
  help           Show this help
EOF
}

DOCKER_COMPOSE=(docker-compose)
if docker compose version >/dev/null 2>&1; then
    DOCKER_COMPOSE=(docker compose)
fi

DOCKER_COMPOSE_UP_ARGS=(--detach --remove-orphans)
DOCKER_COMPOSE_RESTART_ARGS=(--detach --force-recreate --remove-orphans)
DOCKER_COMPOSE_REBUILD_ARGS=(--detach --build --force-recreate --remove-orphans)

op="${1:-status}"
shift || true

case $op in
on | up | start)
    if stack_ready; then
        echo "VPN stack is already running; nothing to do."
        exit 0
    fi
    start_vpn "${DOCKER_COMPOSE_UP_ARGS[@]}" "$@"
    ;;
off)
    (cd "$CODE_PATH" && "${DOCKER_COMPOSE[@]}" down "$@")
    ;;
restart)
    start_vpn "${DOCKER_COMPOSE_RESTART_ARGS[@]}" "$@"
    ;;
rebuild)
    start_vpn "${DOCKER_COMPOSE_REBUILD_ARGS[@]}" "$@"
    ;;
clear)
    rm -f "${COOKIE_PATH}"
    start_vpn "${DOCKER_COMPOSE_RESTART_ARGS[@]}" "$@"
    ;;
clean)
    (cd "$CODE_PATH" && "${DOCKER_COMPOSE[@]}" down --remove-orphans "$@")
    rm -f "${COOKIE_PATH}"
    ;;
status)
    (cd "$CODE_PATH" && "${DOCKER_COMPOSE[@]}" ps "$@")
    ;;
help | -h | --help)
    usage
    ;;
*) # unknown option
    (cd "$CODE_PATH" && "${DOCKER_COMPOSE[@]}" "$op" "$@")
    ;;
esac
