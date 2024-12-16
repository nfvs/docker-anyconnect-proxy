#!/usr/bin/env bash

SCRIPT_PATH="$(readlink -f "$(readlink "${BASH_SOURCE[0]}")")"
CODE_PATH=$(dirname "${SCRIPT_PATH}")

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

saml_flow() {
    local output
    output=$(openconnect --useragent="AnyConnect-compatible OpenConnect VPN Agent" --authenticate "${ANYCONNECT_SERVER}/SAML-EXT")
    # Parse the variables using grep and sed
    ANYCONNECT_COOKIE=$(echo "$output" | grep -Eo "COOKIE='[^']+" | cut -d"'" -f2)
    ANYCONNECT_SERVER=$(echo "$output" | grep -Eo "CONNECT_URL='[^']+" | cut -d"'" -f2)
    ANYCONNECT_CERT=$(echo "$output" | grep -Eo "FINGERPRINT='[^']+" | cut -d"'" -f2)
    ANYCONNECT_RESOLVE=$(echo "$output" | grep -Eo "RESOLVE='[^']+" | cut -d"'" -f2)
    export ANYCONNECT_COOKIE
    export ANYCONNECT_SERVER
    export ANYCONNECT_CERT
    export ANYCONNECT_RESOLVE
}

DOCKER_COMPOSE="docker-compose"
if [ -n "$(docker compose)" ]; then
    DOCKER_COMPOSE="docker compose"
fi

DOCKER_COMPOSE_UP_ARGS="--detach"

op="$1"

case $op in
on | up)
    # read_credentials "$@"
    saml_flow
    (cd "$CODE_PATH" && ${DOCKER_COMPOSE} up ${DOCKER_COMPOSE_UP_ARGS})
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
