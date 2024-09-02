#!/bin/bash

if [ $EUID != 0 ]; then
    sudo "$0" "$@"
    exit $?
fi

CURDIR=$(dirname $(realpath $0))

# Defaults
ANYCONNECT_USERAGENT=${ANYCONNECT_USERAGENT:-"AnyConnect Windows 4.10.07062"}

if [ -f "$CURDIR/.env" ]; then
    source "$CURDIR/.env"
fi

if [ ! -f "$HOME/.csd-wrapper.sh" ]; then
    wget --no-check-certificate https://gist.github.com/l0ki000/56845c00fd2a0e76d688/raw/61fc41ac8aec53ae0f9f0dfbfa858c1740307de4/csd-wrapper.sh -O "$HOME/.csd-wrapper.sh"
fi

# Fill in hostname in csd-wrapper file
sed -i "s/^CSD_HOSTNAME=.*$/CSD_HOSTNAME=${ANYCONNECT_SERVER}/" $HOME/.csd-wrapper.sh

OPENCONNECT_ARGS=("$ANYCONNECT_SERVER" --allow-insecure-crypto --user="$ANYCONNECT_USER" --authgroup="$ANYCONNECT_GROUP" --timestamp --passwd-on-stdin --servercert "$ANYCONNECT_CERT" --useragent ${ANYCONNECT_USERAGENT})

if [[ -n "$ANYCONNECT_CERT" ]]; then
    OPENCONNECT_ARGS+=(--servercert "${ANYCONNECT_CERT}")
fi

echo "$ANYCONNECT_PASSWORD" | openconnect "${OPENCONNECT_ARGS[@]}"

