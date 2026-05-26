#!/usr/bin/env bash

set -e

SCRIPT_PATH="${BASH_SOURCE[0]}"
while [[ -L "$SCRIPT_PATH" ]]; do
    SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_PATH")" && pwd)"
    SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"
    [[ "$SCRIPT_PATH" != /* ]] && SCRIPT_PATH="${SCRIPT_DIR}/${SCRIPT_PATH}"
done

CODE_PATH="$(cd -P "$(dirname "$SCRIPT_PATH")" && pwd)"
COOKIE_PATH="${CODE_PATH}/.cookie"

if [ -f "$CODE_PATH/.env" ]; then
    source "$CODE_PATH/.env"
fi

ANYCONNECT_USERAGENT="${ANYCONNECT_USERAGENT:-AnyConnect-compatible OpenConnect VPN Agent}"

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
}

write_cookie_file() {
    local tmp_path

    tmp_path="$(umask 077 && mktemp "${COOKIE_PATH}.XXXXXX")"
    {
        printf 'export ANYCONNECT_SERVER=%q\n' "$ANYCONNECT_SERVER"
        printf 'export ANYCONNECT_CONNECT_URL=%q\n' "${ANYCONNECT_CONNECT_URL:-}"
        printf 'export ANYCONNECT_HOST=%q\n' "${ANYCONNECT_HOST:-}"
        printf 'export ANYCONNECT_CERT=%q\n' "${ANYCONNECT_CERT:-}"
        printf 'export ANYCONNECT_RESOLVE=%q\n' "${ANYCONNECT_RESOLVE:-}"
        printf 'export ANYCONNECT_COOKIE=%q\n' "$ANYCONNECT_COOKIE"
    } >"${tmp_path}"

    chmod 600 "${tmp_path}"
    mv "${tmp_path}" "${COOKIE_PATH}"
}

compose_up() {
    (cd "$CODE_PATH" && "${DOCKER_COMPOSE[@]}" up "${DOCKER_COMPOSE_UP_ARGS[@]}" "$@")
    docker logs --tail 80 anyconnect_vpn
}

start_vpn() {
    authenticate
    compose_up "$@"
}

refresh_cookie() {
    local output status connect_target
    local openconnect_args

    connect_target="${ANYCONNECT_CONNECT_URL:-${ANYCONNECT_HOST:-$ANYCONNECT_SERVER}}"
    echo "Refreshing existing cookie..."

    openconnect_args=(
        --authenticate
        --useragent="${ANYCONNECT_USERAGENT}"
        --cookie="${ANYCONNECT_COOKIE}"
    )

    [[ -n "${ANYCONNECT_RESOLVE:-}" ]] && openconnect_args+=(--resolve "${ANYCONNECT_RESOLVE}")
    [[ -n "${ANYCONNECT_CERT:-}" ]] && openconnect_args+=(--servercert "${ANYCONNECT_CERT}")

    set +e
    output=$(openconnect "${openconnect_args[@]}" "${connect_target}" 2>&1)
    status=$?
    set -e

    if ((status != 0)) || ! parse_auth_output "$output"; then
        echo "Authentication with the existing cookie failed, re-authenticating..."
        ANYCONNECT_COOKIE=""
        return 1
    fi

    echo "Authentication with the existing cookie was successful."
    write_cookie_file
}

saml_flow() {
    local output
    local openconnect_args
    local configured_server="${ANYCONNECT_SERVER}"
    local configured_connect_url="${ANYCONNECT_CONNECT_URL:-}"
    local configured_host="${ANYCONNECT_HOST:-}"
    local configured_cert="${ANYCONNECT_CERT:-}"
    local configured_resolve="${ANYCONNECT_RESOLVE:-}"
    local cached_server

    if [[ -s "$COOKIE_PATH" ]]; then
        echo "Using existing cookie..."
        # shellcheck disable=SC1090
        source "${COOKIE_PATH}"
        cached_server="${ANYCONNECT_SERVER:-}"

        if [[ -n "$cached_server" && "$cached_server" != "$configured_server" ]]; then
            echo "Ignoring existing cookie for ${cached_server}; configured server is ${configured_server}."
            ANYCONNECT_COOKIE=""
        elif [[ -n "${ANYCONNECT_COOKIE:-}" ]]; then
            refresh_cookie || true
        fi
    fi

    if [[ -z "${ANYCONNECT_COOKIE}" ]]; then
        ANYCONNECT_SERVER="$configured_server"
        ANYCONNECT_CONNECT_URL="$configured_connect_url"
        ANYCONNECT_HOST="$configured_host"
        ANYCONNECT_CERT="$configured_cert"
        ANYCONNECT_RESOLVE="$configured_resolve"

        echo "Connecting to ${ANYCONNECT_SERVER}..."
        openconnect_args=(
            --useragent="${ANYCONNECT_USERAGENT}"
            --authenticate
        )

        [[ -n "${ANYCONNECT_RESOLVE:-}" ]] && openconnect_args+=(--resolve "${ANYCONNECT_RESOLVE}")
        [[ -n "${ANYCONNECT_CERT:-}" ]] && openconnect_args+=(--servercert "${ANYCONNECT_CERT}")

        output=$(openconnect "${openconnect_args[@]}" "${ANYCONNECT_SERVER}")
        if ! parse_auth_output "$output"; then
            echo "Failed to parse authentication cookie from openconnect output."
            exit 1
        fi

        write_cookie_file
    fi

    export ANYCONNECT_COOKIE
    export ANYCONNECT_SERVER
    export ANYCONNECT_CONNECT_URL
    export ANYCONNECT_HOST
    export ANYCONNECT_CERT
    export ANYCONNECT_RESOLVE
    export ANYCONNECT_PUBLIC_KEY
    export ANYCONNECT_USER
    export ANYCONNECT_USERAGENT
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [up|start|on|off|restart|clear|clean|status|help|docker-compose args...]

Commands:
  up, start, on  Refresh or create the cookie, then start the VPN stack
  off            Stop and remove the stack, keeping the cookie
  restart        Refresh the cookie and recreate the stack
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

DOCKER_COMPOSE_UP_ARGS=(--detach --force-recreate --remove-orphans)

op="${1:-status}"
shift || true

case $op in
on | up | start)
    start_vpn "$@"
    ;;
off)
    (cd "$CODE_PATH" && "${DOCKER_COMPOSE[@]}" down "$@")
    ;;
clear)
    rm -f "${COOKIE_PATH}"
    start_vpn "$@"
    ;;
clean)
    (cd "$CODE_PATH" && "${DOCKER_COMPOSE[@]}" down --remove-orphans "$@")
    rm -f "${COOKIE_PATH}"
    ;;
restart)
    start_vpn "$@"
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
