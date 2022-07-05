#!/bin/bash

if [ $EUID != 0 ]; then
    sudo "$0" "$@"
    exit $?
fi

CURDIR=$(dirname $(realpath $0))

if [ -f "$CURDIR/.env" ]; then
    source "$CURDIR/.env"
fi

if [ ! -f "$HOME/.csd-wrapper.sh" ]; then
    wget --no-check-certificate https://gist.github.com/l0ki000/56845c00fd2a0e76d688/raw/61fc41ac8aec53ae0f9f0dfbfa858c1740307de4/csd-wrapper.sh -O "$HOME/.csd-wrapper.sh"
fi

# Fill in hostname in csd-wrapper file
sed -i "s/^CSD_HOSTNAME=.*$/CSD_HOSTNAME=${ANYCONNECT_SERVER}/" $HOME/.csd-wrapper.sh

OPENCONNECT_ARGS=("$ANYCONNECT_SERVER" --user="$ANYCONNECT_USER" --authgroup="$ANYCONNECT_GROUP" --timestamp --passwd-on-stdin --servercert "$ANYCONNECT_CERT")

( echo "$ANYCONNECT_PASSWORD" ) | openconnect ${OPENCONNECT_ARGS[@]} $@

