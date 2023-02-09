#!/usr/bin/env bash

SCRIPT_PATH="$(readlink -f "$(readlink "${BASH_SOURCE[0]}")")"
CODE_PATH=$(dirname "${SCRIPT_PATH}")

read_credentials() {
    # Add password to mac keychain: security add-generic-password -a <user> -s <service> -w
    if command -v security > /dev/null 2>&1; then
        ANYCONNECT_PASSWORD=$(security find-generic-password -a $(id -un) -s anyconnect_vpn -w)
        if [ -z "$2" ]; then
            echo "No login code provided, use 'up <code>' instead.";
            echo -n "Enter code: ";
            read -p ANYCONNECT_CODE;
        else
            ANYCONNECT_CODE="$2"
        fi
        ANYCONNECT_PASSWORD="$ANYCONNECT_PASSWORD,$ANYCONNECT_CODE"
    else
        echo "Enter the password, followed by a comma and the code";
        read -s ANYCONNECT_PASSWORD;
    fi

    export ANYCONNECT_PASSWORD
}

DOCKER_COMPOSE="docker-compose"
# if [ -n "$(docker compose)" ]; then
#     DOCKER_COMPOSE="docker compose"
# fi

DOCKER_COMPOSE_UP_ARGS="--detach"

op="$1"

case $op in
    on|up)
    read_credentials "$@"
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
    *)    # unknown option
    (cd "$CODE_PATH" && ${DOCKER_COMPOSE} $op)
    shift # past argument
    ;;
esac

