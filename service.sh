#!/usr/bin/env bash

set -e

SCRIPT_PATH="$(readlink -f "$(readlink "${BASH_SOURCE[0]}")")"
CODE_PATH=$(dirname "${SCRIPT_PATH}")
COOKIE_PATH="${CODE_PATH}/.cookie"
ANYCONNECT_USERAGENT="AnyConnect-compatible OpenConnect VPN Agent"

if [ -f "$CODE_PATH/.env" ]; then
    source "$CODE_PATH/.env"
fi

read_credentials() {
    # Add password to mac keychain: security add-generic-password -a <user> -s <service> -w
    if command -v security >/dev/null 2>&1; then
        ANYCONNECT_PASSWORD=$(security find-generic-password -a "$(id -un)" -s anyconnect_vpn -w)
        if [ -z "$2" ]; then
            echo "No login code provided, use 'up <code>' instead."
            echo -n "Enter code: "
            read -pr ANYCONNECT_CODE
        else
            ANYCONNECT_CODE="$2"
        fi
        ANYCONNECT_PASSWORD="$ANYCONNECT_PASSWORD,$ANYCONNECT_CODE"
    else
        echo "Enter the password, followed by a comma and the code"
        read -s ANYCONNECT_PASSWORD
    fi

    export ANYCONNECT_PASSWORD
}

authenticate() {
    if [[ "${ANYCONNECT_SERVER}" == *"/SAML-EXT" ]]; then
        saml_flow
    else
        echo "Unsupported server: ${ANYCONNECT_SERVER}; only SAML-EXT is supported"
        exit 1
    fi
}

saml_flow() {
    local output

    # Test connection first; if it succeeds, the cookie is still valid so pass it along to the container
    if [[ -s "$COOKIE_PATH" ]]; then
        echo "Using existing cookie..."
        # shellcheck disable=SC1090
        source "${COOKIE_PATH}"

        OPENCONNECT_ARGS=(
            "$ANYCONNECT_SERVER" \
            --useragent="${ANYCONNECT_USERAGENT}" \
            --cookie "${ANYCONNECT_COOKIE}" \
            --resolve "${ANYCONNECT_RESOLVE}" \
            --servercert "${ANYCONNECT_CERT}" \
            --authenticate
        )

        # output=$(openconnect "${OPENCONNECT_ARGS[@]}" <<<"${ANYCONNECT_COOKIE}")
        output=$(openconnect "${OPENCONNECT_ARGS[@]}")
        ANYCONNECT_COOKIE=$(echo "$output" | grep -Eo "COOKIE='[^']+" | cut -d"'" -f2)
        # echo "OUTPUT"
        # echo "$output"
        # echo "--------"

        # Cookie is valid; load all ANYCONNECT_* variables
        if [[ -n "${ANYCONNECT_COOKIE}" ]]; then
            echo "Authentication with the existing cookie was successful."
        # Cookie isn't valid, remove the cookie and set output="" to trigger re-authentication
        else
            echo "Authentication with the existing cookie failed, re-authenticating..."
            # output=""
            # rm -f "$COOKIE_PATH"
        fi

    fi

    if [[ -z "${ANYCONNECT_COOKIE}" ]]; then
        output=$(openconnect --useragent="${ANYCONNECT_USERAGENT}" --authenticate "${ANYCONNECT_SERVER}")

        # Parse the variables using grep and sed
        ANYCONNECT_COOKIE=$(echo "$output" | grep -Eo "COOKIE='[^']+" | cut -d"'" -f2)
        ANYCONNECT_SERVER="$(echo "$output" | grep -Eo "CONNECT_URL='[^']+" | cut -d"'" -f2)"
        ANYCONNECT_CERT=$(echo "$output" | grep -Eo "FINGERPRINT='[^']+" | cut -d"'" -f2)
        ANYCONNECT_RESOLVE=$(echo "$output" | grep -Eo "RESOLVE='[^']+" | cut -d"'" -f2)

        cat <<EOF >"${COOKIE_PATH}"
export ANYCONNECT_SERVER='$ANYCONNECT_SERVER'
export ANYCONNECT_CERT='$ANYCONNECT_CERT'
export ANYCONNECT_RESOLVE='$ANYCONNECT_RESOLVE'
export ANYCONNECT_COOKIE='$ANYCONNECT_COOKIE'
EOF
    fi

    export ANYCONNECT_COOKIE
    export ANYCONNECT_SERVER
    export ANYCONNECT_CERT
    export ANYCONNECT_RESOLVE
    export ANYCONNECT_PUBLIC_KEY
    export ANYCONNECT_USER
    export ANYCONNECT_USERAGENT
}

DOCKER_COMPOSE="docker-compose"
if [ -n "$(docker compose)" ]; then
    DOCKER_COMPOSE="docker compose"
fi

DOCKER_COMPOSE_UP_ARGS="--detach"

op="$1"

case $op in
on | up)
    authenticate
    (cd "$CODE_PATH" && ${DOCKER_COMPOSE} up ${DOCKER_COMPOSE_UP_ARGS})
    docker logs anyconnect_vpn
    shift
    ;;
off)
    (cd "$CODE_PATH" && ${DOCKER_COMPOSE} down)
    shift
    ;;
clean)
    (cd "$CODE_PATH" && ${DOCKER_COMPOSE} rm -f)
    shift
    ;;
restart)
    (cd "$CODE_PATH" && docker restart anyconnect_vpn)
    shift
    ;;
# rm)
# (cd "$CODE_PATH" && ${DOCKER_COMPOSE} rm)
# shift
# ;;
status)
    (cd "$CODE_PATH" && ${DOCKER_COMPOSE} ps)
    shift
    ;;
*) # unknown option
    (cd "$CODE_PATH" && ${DOCKER_COMPOSE} $op)
    shift # past argument
    ;;
esac
