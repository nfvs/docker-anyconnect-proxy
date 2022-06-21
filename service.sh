#!/usr/bin/env sh

CODE_PATH="$HOME/.docker-anyconnect"

# Add password to mac keychain: security add-generic-password -a <user> -s <service> -w
ANYCONNECT_PASSWORD=$(security find-generic-password -a $(id -un) -s anyconnect_vpn -w)
# Duo code?
if [ -n "$2" ]; then
    ANYCONNECT_PASSWORD="$ANYCONNECT_PASSWORD,$2"
fi
export ANYCONNECT_PASSWORD

DOCKER_COMPOSE="docker-compose"
# if [ -n "$(docker compose)" ]; then
#     DOCKER_COMPOSE="docker compose"
# fi

DOCKER_COMPOSE_UP_ARGS="--detach"

op="$1"

case $op in
    on|up)
    if [ -z "$2" ]; then
        echo "No login code provided, use 'up <code>' instead."
        exit 1
    fi
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

