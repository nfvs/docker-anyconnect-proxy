#!/bin/bash

set -e

# Defaults
ANYCONNECT_USERAGENT=${ANYCONNECT_USERAGENT:-"AnyConnect-compatible OpenConnect VPN Agent"}

COOKIE_FILE="${ANYCONNECT_COOKIE_FILE:-/run/anyconnect/cookie}"
if [[ ! -f "$COOKIE_FILE" ]]; then
    echo "Missing cookie file: $COOKIE_FILE"
    echo "Run ./service.sh clear to authenticate and create one."
    exit 1
fi

source "$COOKIE_FILE"

if [[ -z "${ANYCONNECT_COOKIE:-}" ]]; then
    echo "Cookie file does not contain ANYCONNECT_COOKIE: $COOKIE_FILE"
    exit 1
fi

CONNECT_TARGET="${ANYCONNECT_CONNECT_URL:-${ANYCONNECT_HOST:-$ANYCONNECT_SERVER}}"
if [[ -z "$CONNECT_TARGET" ]]; then
    echo "Cookie file does not contain a VPN connect target."
    exit 1
fi

OPENCONNECT_ARGS=(
    "$CONNECT_TARGET"
    --cookie-on-stdin
    --useragent "${ANYCONNECT_USERAGENT}"
)

[[ -n "${ANYCONNECT_RESOLVE:-}" ]] && OPENCONNECT_ARGS+=(--resolve "${ANYCONNECT_RESOLVE}")
[[ -n "${ANYCONNECT_CERT:-}" ]] && OPENCONNECT_ARGS+=(--servercert "${ANYCONNECT_CERT}")

exec openconnect "${OPENCONNECT_ARGS[@]}" <<<"${ANYCONNECT_COOKIE}"
