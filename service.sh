#!/usr/bin/env sh

CODE_PATH="$HOME/.docker-anyconnect"

# Add password to mac keychain: security add-generic-password -a <user> -s <service> -w
ANYCONNECT_PASSWORD=$(security find-generic-password -a $(id -un) -s ngvpn.nvidia.com -w)
export ANYCONNECT_PASSWORD

DOCKER_COMPOSE="docker-compose"
# if [ -n "$(docker compose)" ]; then
#     DOCKER_COMPOSE="docker compose"
# fi

DOCKER_COMPOSE_UP_ARGS="--detach"

while [ "$#" -gt 0 ]
do
key="$1"

case $key in
    on|up)
    (cd "$CODE_PATH" && ${DOCKER_COMPOSE} up ${DOCKER_COMPOSE_UP_ARGS})
    shift
    ;;
    off|down)
    (cd "$CODE_PATH" && ${DOCKER_COMPOSE} down)
    shift
    ;;
    restart)
    (cd "$CODE_PATH" && docker restart ngvpn_vpn)
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
done

