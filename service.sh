#!/usr/bin/env sh

CODE_PATH="$HOME/.docker-anyconnect"

# Add password to mac keychain: security add-generic-password -a <user> -s <service> -w
ANYCONNECT_PASSWORD=$(security find-generic-password -a <user> -s <service> -w)
export ANYCONNECT_PASSWORD

while [[ $# -gt 0 ]]
do
key="$1"

case $key in
    on|up)
    (cd "$CODE_PATH" && docker-compose up -d)
    shift
    ;;
    off|down)
    (cd "$CODE_PATH" && docker-compose down)
    shift
    ;;
    restart)
    (cd "$CODE_PATH" && docker-compose restart)
    shift
    ;;
    ps|status)
    (cd "$CODE_PATH" && docker-compose ps)
    shift
    ;;
    *)    # unknown option
    shift # past argument
    ;;
esac
done

