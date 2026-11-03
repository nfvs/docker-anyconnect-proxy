#!/usr/bin/env bash

set -euo pipefail

CODE_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_PATH="$(mktemp -d)"
trap 'rm -rf "$TEST_PATH"' EXIT
mkdir -p "$TEST_PATH/bin"

cat >"$TEST_PATH/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$1" in
compose)
    [[ "$2" == version ]] && exit 0
    [[ "$2" == up ]] || exit 2
    count=0
    [[ ! -f "$MOCK_CASE_PATH/up.count" ]] || count=$(cat "$MOCK_CASE_PATH/up.count")
    count=$((count + 1))
    printf '%s\n' "$count" >"$MOCK_CASE_PATH/up.count"
    printf '%s\n' "$@" >"$MOCK_CASE_PATH/up.$count.args"
    cp .state/cookie "$MOCK_CASE_PATH/up.$count.cookie"
    [[ "$count" != 1 && "$MOCK_SCENARIO" != retry_failure ]]
    ;;
inspect)
    if [[ "$MOCK_SCENARIO" == healthy ]]; then
        echo 'running healthy'
    else
        echo 'exited unhealthy'
    fi
    ;;
logs)
    printf '%s\n' "$@" >>"$MOCK_CASE_PATH/log.args"
    since=''
    while [[ "$#" != 0 ]]; do
        if [[ "$1" == --since ]]; then
            since="$2"
            shift
        fi
        shift
    done
    if [[ -n "$since" && ! "$since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
        echo 'Unsupported log timestamp' >&2
        exit 2
    fi
    case "$MOCK_SCENARIO" in
    cookie)
        echo 'Cookie was rejected by server'
        ;;
    unauthorized)
        echo 'HTTP/1.1 401 Unauthorized'
        ;;
    generic_tls)
        echo 'Server certificate verify failed: self-signed certificate in certificate chain'
        echo 'SSL connection failure'
        ;;
    proxy_failure)
        echo 'VPN tunnel is connected'
        ;;
    stale_pin | stale_cookie)
        if [[ -n "$since" ]]; then
            echo 'Temporary network failure'
        elif [[ "$MOCK_SCENARIO" == stale_pin ]]; then
            echo "None of the 1 fingerprint(s) specified via --servercert match server's certificate: pin-sha256:untrusted-log-value"
        else
            echo 'Cookie was rejected by server'
        fi
        ;;
    *)
        count=1
        [[ "$MOCK_SCENARIO" != pin_multiple ]] || count=3
        echo "None of the $count fingerprint(s) specified via --servercert match server's certificate: pin-sha256:untrusted-log-value"
        ;;
    esac
    ;;
*)
    exit 2
    ;;
esac
EOF

cat >"$TEST_PATH/bin/openconnect" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

echo auth >>"$MOCK_CASE_PATH/auth.calls"
printf '%s\n' "$@" >"$MOCK_CASE_PATH/auth.args"
printf '%s\n' \
    "server=${ANYCONNECT_SERVER:-}" \
    "cert=${ANYCONNECT_CERT:-}" \
    "resolve=${ANYCONNECT_RESOLVE:-}" \
    "host=${ANYCONNECT_HOST:-}" \
    "connect_url=${ANYCONNECT_CONNECT_URL:-}" \
    "cookie=${ANYCONNECT_COOKIE:-}" >"$MOCK_CASE_PATH/auth.env"
[[ ! -f "$MOCK_CASE_PATH/.state/cookie" ]] || touch "$MOCK_CASE_PATH/auth.used-cache"

if [[ "$MOCK_SCENARIO" == auth_parse_failure ]]; then
    echo "FINGERPRINT='pin-sha256:fresh-pin'"
    exit 0
fi

echo "COOKIE='fresh-cookie'"
[[ "$MOCK_SCENARIO" != auth_failure ]] || exit 23
[[ "$MOCK_SCENARIO" != pin_configured_defaults && "$MOCK_SCENARIO" != pin_cache_only_defaults ]] || exit 0
echo "FINGERPRINT='pin-sha256:fresh-pin'"
echo "RESOLVE='fresh.vpn.example:192.0.2.20'"
echo "HOST='fresh.vpn.example'"
echo "CONNECT_URL='https://fresh.vpn.example'"
EOF
chmod +x "$TEST_PATH/bin/docker" "$TEST_PATH/bin/openconnect"

fail() {
    echo "FAIL: $MOCK_SCENARIO: $*" >&2
    cat "$MOCK_CASE_PATH/output" >&2
    exit 1
}

assert_line() {
    grep -Fxq -- "$2" "$1" || fail "missing '$2' in $(basename "$1")"
}

assert_missing() {
    [[ ! -e "$1" ]] || fail "unexpected $(basename "$1")"
}

assert_cookie() {
    (
        source "$1"
        [[ "${!2}" == "$3" ]]
    ) || fail "unexpected $2 in $(basename "$1")"
}

run_case() {
    local expected_status="$2" expected_auth="$3" expected_up="$4"
    local status=0 auth_count=0 up_count=0
    export MOCK_SCENARIO="$1" MOCK_CASE_PATH="$TEST_PATH/$1"

    mkdir -p "$MOCK_CASE_PATH/.state"
    cp "$CODE_PATH/service.sh" "$MOCK_CASE_PATH/service.sh"
    echo "ANYCONNECT_SERVER='configured.vpn.example/SAML-EXT'" >"$MOCK_CASE_PATH/.env"
    if [[ "$MOCK_SCENARIO" == pin_configured_defaults ]]; then
        cat >>"$MOCK_CASE_PATH/.env" <<'EOF'
ANYCONNECT_CERT='pin-sha256:configured-pin'
ANYCONNECT_RESOLVE='configured.vpn.example:192.0.2.10'
ANYCONNECT_HOST='configured.vpn.example'
ANYCONNECT_CONNECT_URL='https://configured.vpn.example'
EOF
    fi
    if [[ "$MOCK_SCENARIO" != fresh_pin ]]; then
        cat >"$MOCK_CASE_PATH/.state/cookie" <<'EOF'
export ANYCONNECT_SERVER='configured.vpn.example/SAML-EXT'
export ANYCONNECT_COOKIE='cached-cookie'
export ANYCONNECT_CERT='pin-sha256:cached-pin'
export ANYCONNECT_RESOLVE='cached.vpn.example:192.0.2.30'
export ANYCONNECT_HOST='cached.vpn.example'
export ANYCONNECT_CONNECT_URL='https://cached.vpn.example'
EOF
    fi

    PATH="$TEST_PATH/bin:$PATH" bash "$MOCK_CASE_PATH/service.sh" on >"$MOCK_CASE_PATH/output" 2>&1 || status=$?
    [[ ! -f "$MOCK_CASE_PATH/auth.calls" ]] || auth_count=$(wc -l <"$MOCK_CASE_PATH/auth.calls")
    [[ ! -f "$MOCK_CASE_PATH/up.count" ]] || up_count=$(cat "$MOCK_CASE_PATH/up.count")
    [[ "$status" == "$expected_status" ]] || fail "exit $status, expected $expected_status"
    [[ "$auth_count" -eq "$expected_auth" ]] || fail "$auth_count authentications, expected $expected_auth"
    [[ "$up_count" == "$expected_up" ]] || fail "$up_count startups, expected $expected_up"

    if [[ "$up_count" != 0 ]]; then
        assert_line "$MOCK_CASE_PATH/log.args" --since
    fi
    if [[ "$expected_auth" != 0 ]]; then
        assert_line "$MOCK_CASE_PATH/auth.args" configured.vpn.example/SAML-EXT
        assert_line "$MOCK_CASE_PATH/auth.args" --authenticate
        assert_missing "$MOCK_CASE_PATH/auth.used-cache"
        assert_line "$MOCK_CASE_PATH/auth.env" cookie=
        if [[ "$MOCK_SCENARIO" == pin_configured_defaults ]]; then
            assert_line "$MOCK_CASE_PATH/auth.args" --servercert
            assert_line "$MOCK_CASE_PATH/auth.args" pin-sha256:configured-pin
            assert_line "$MOCK_CASE_PATH/auth.args" --resolve
            assert_line "$MOCK_CASE_PATH/auth.args" configured.vpn.example:192.0.2.10
            assert_line "$MOCK_CASE_PATH/auth.env" cert=pin-sha256:configured-pin
            assert_line "$MOCK_CASE_PATH/auth.env" resolve=configured.vpn.example:192.0.2.10
            assert_line "$MOCK_CASE_PATH/auth.env" host=configured.vpn.example
            assert_line "$MOCK_CASE_PATH/auth.env" connect_url=https://configured.vpn.example
        else
            assert_line "$MOCK_CASE_PATH/auth.env" cert=
            assert_line "$MOCK_CASE_PATH/auth.env" resolve=
            assert_line "$MOCK_CASE_PATH/auth.env" host=
            assert_line "$MOCK_CASE_PATH/auth.env" connect_url=
            if grep -Eq -- '--servercert|--resolve|--no-cert-check|--no-system-trust|untrusted-log-value' "$MOCK_CASE_PATH/auth.args"; then
                fail 'fresh authentication used cached or unverified trust/routing settings'
            fi
        fi
    fi
    if [[ "$expected_up" == 2 ]]; then
        assert_line "$MOCK_CASE_PATH/up.2.args" --force-recreate
        assert_cookie "$MOCK_CASE_PATH/up.2.cookie" ANYCONNECT_COOKIE fresh-cookie
        case "$MOCK_SCENARIO" in
        pin_configured_defaults)
            assert_cookie "$MOCK_CASE_PATH/up.2.cookie" ANYCONNECT_CERT pin-sha256:configured-pin
            assert_cookie "$MOCK_CASE_PATH/up.2.cookie" ANYCONNECT_RESOLVE configured.vpn.example:192.0.2.10
            assert_cookie "$MOCK_CASE_PATH/up.2.cookie" ANYCONNECT_HOST configured.vpn.example
            assert_cookie "$MOCK_CASE_PATH/up.2.cookie" ANYCONNECT_CONNECT_URL https://configured.vpn.example
            ;;
        pin_cache_only_defaults)
            assert_cookie "$MOCK_CASE_PATH/up.2.cookie" ANYCONNECT_CERT ''
            assert_cookie "$MOCK_CASE_PATH/up.2.cookie" ANYCONNECT_RESOLVE ''
            assert_cookie "$MOCK_CASE_PATH/up.2.cookie" ANYCONNECT_HOST ''
            assert_cookie "$MOCK_CASE_PATH/up.2.cookie" ANYCONNECT_CONNECT_URL ''
            ;;
        *)
            assert_cookie "$MOCK_CASE_PATH/up.2.cookie" ANYCONNECT_CERT pin-sha256:fresh-pin
            assert_cookie "$MOCK_CASE_PATH/up.2.cookie" ANYCONNECT_RESOLVE fresh.vpn.example:192.0.2.20
            assert_cookie "$MOCK_CASE_PATH/up.2.cookie" ANYCONNECT_HOST fresh.vpn.example
            assert_cookie "$MOCK_CASE_PATH/up.2.cookie" ANYCONNECT_CONNECT_URL https://fresh.vpn.example
            ;;
        esac
    elif [[ "$MOCK_SCENARIO" == auth_failure || "$MOCK_SCENARIO" == auth_parse_failure ]]; then
        assert_missing "$MOCK_CASE_PATH/.state/cookie"
    elif [[ "$expected_auth" == 0 ]]; then
        assert_cookie "$MOCK_CASE_PATH/.state/cookie" ANYCONNECT_COOKIE cached-cookie
    fi
    echo "PASS: $MOCK_SCENARIO"
}

run_case pin 0 1 2
run_case pin_multiple 0 1 2
run_case cookie 0 1 2
run_case unauthorized 0 1 2
run_case pin_configured_defaults 0 1 2
run_case pin_cache_only_defaults 0 1 2
run_case generic_tls 1 0 1
run_case proxy_failure 1 0 1
run_case stale_pin 1 0 1
run_case stale_cookie 1 0 1
run_case fresh_pin 1 1 1
run_case retry_failure 1 1 2
run_case auth_failure 23 1 1
run_case auth_parse_failure 1 1 1
run_case healthy 0 0 0
