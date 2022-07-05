#!/usr/bin/env bash

CODE_PATH="$HOME/.docker-anyconnect-proxy"

read_credentials() {
    # Add password to mac keychain: security add-generic-password -a <user> -s <service> -w
    if command -v security > /dev/null 2>&1; then
        ANYCONNECT_PASSWORD=$(security find-generic-password -a $(id -un) -s anyconnect_vpn -w)
        if [ -z "$2" ]; then
            echo "No login code provided, use 'up <code>' instead.";
            echo -n "Enter code: ";
            read -p ANYCONNECT_CODE;
            ANYCONNECT_PASSWORD="$ANYCONNECT_PASSWORD,$ANYCONNECT_CODE"
        fi
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
    read_credentials
    (cd "$CODE_PATH" && ${DOCKER_COMPOSE} up ${DOCKER_COMPOSE_UP_ARGS})
    shift
    ;;
    off|down)
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
    rm)
    (cd "$CODE_PATH" && ${DOCKER_COMPOSE} rm)
    shift
    ;;
    ps|status)
    (cd "$CODE_PATH" && ${DOCKER_COMPOSE} ps)
    shift
    ;;
    *)    # unknown option
    shift # past argument
    ;;
esac

