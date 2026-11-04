#!/usr/bin/env bash
# Tests service.sh with mocked `container` and `openconnect` commands.

set -euo pipefail

CODE_PATH="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(cd -P "$(mktemp -d)" && pwd)"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/guest/bin"

SERVER=vpn.example/SAML-EXT
USERAGENT="AnyConnect-compatible OpenConnect VPN Agent"
AUTH_ARGS="--useragent $USERAGENT --authenticate --servercert pin-sha256:configured --resolve vpn.example:192.0.2.10 $SERVER"

# The traffic check runs on the host against this resolv file, with fake `timeout` and `nslookup` commands.
printf '%s\n' 192.0.2.53 192.0.2.54 >"$TEST_ROOT/guest/nameservers"
{
    echo "search vpn.example"
    sed 's/^/nameserver /' "$TEST_ROOT/guest/nameservers"
} >"$TEST_ROOT/guest/resolv.vpn.conf"

cat >"$TEST_ROOT/guest/bin/timeout" <<'EOF'
#!/usr/bin/env bash
shift
exec "$@"
EOF

# Like busybox, prints a "Server:" header once a reply arrives and fails on NXDOMAIN.
cat >"$TEST_ROOT/guest/bin/nslookup" <<'EOF'
#!/usr/bin/env bash
echo "$2" >>"$MOCK_DIR/nslookup.calls"
grep -qxF "$2" "$MOCK_DIR/dns.replying" 2>/dev/null || exit 1
printf 'Server:\t\t%s\n\n** server can'\''t find %s: NXDOMAIN\n' "$2" "$1"
exit 1
EOF

# Each `run` takes the next outcome from MOCK_RUNS; MOCK_FAILS lists subcommands that fail (both space-separated).
cat >"$TEST_ROOT/bin/container" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"$MOCK_DIR/container.calls"

case "$1" in
system) ;;
ls) [[ " $MOCK_FAILS " != *" ls "* ]] ;;
build) [[ " $MOCK_FAILS " != *" build "* ]] ;;
builder) [[ "$2" == stop && " $MOCK_FAILS " != *" builder "* ]] ;;
image) [[ -z "$MOCK_NO_IMAGE" ]] ;;
inspect)
    [[ -f "$MOCK_DIR/state" ]] || exit 1
    printf '[{"status" : {"state" : "%s"}}]\n' "$(cat "$MOCK_DIR/state")"
    ;;
exec)
    check="${!#}"
    if [[ "$check" != *nslookup* ]]; then
        [[ -f "$MOCK_DIR/tunnel" ]]
    elif [[ -f "$MOCK_DIR/dns.late" ]]; then
        mv "$MOCK_DIR/dns.late" "$MOCK_DIR/dns.replying"
        exit 1
    else
        PATH="$MOCK_GUEST/bin:$PATH" sh -c "${check//\/etc\/resolv.vpn.conf/$MOCK_GUEST/resolv.vpn.conf}"
    fi
    ;;
logs) cat "$MOCK_DIR/logs" 2>/dev/null || true ;;
stop) echo stopped >"$MOCK_DIR/state" && rm -f "$MOCK_DIR/tunnel" "$MOCK_DIR/dns.replying" "$MOCK_DIR/dns.late" ;;
delete) rm -f "$MOCK_DIR/state" "$MOCK_DIR/tunnel" "$MOCK_DIR/dns.replying" "$MOCK_DIR/dns.late" "$MOCK_DIR/logs" ;;
run)
    runs=$(grep -c '^run ' "$MOCK_DIR/container.calls")
    read -ra outcomes <<<"$MOCK_RUNS"
    cp "$MOCK_COOKIE" "$MOCK_DIR/run.$runs.cookie"
    echo running >"$MOCK_DIR/state"
    case "${outcomes[runs - 1]:-}" in
    ready) touch "$MOCK_DIR/tunnel" && cp "$MOCK_GUEST/nameservers" "$MOCK_DIR/dns.replying" ;;
    first_dns_silent) touch "$MOCK_DIR/tunnel" && tail -n +2 "$MOCK_GUEST/nameservers" >"$MOCK_DIR/dns.replying" ;;
    late_traffic) touch "$MOCK_DIR/tunnel" && cp "$MOCK_GUEST/nameservers" "$MOCK_DIR/dns.late" ;;
    no_traffic) touch "$MOCK_DIR/tunnel" ;;
    hang) ;;
    rejected) echo 'Cookie was rejected by server' >"$MOCK_DIR/logs" ;;
    unauthorized) echo 'HTTP/1.1 401 Unauthorized' >"$MOCK_DIR/logs" ;;
    pin) echo "None of the 1 fingerprint(s) specified via --servercert match server's certificate" >"$MOCK_DIR/logs" ;;
    other) echo 'SSL connection failure' >"$MOCK_DIR/logs" ;;
    exit_after_tunnel) touch "$MOCK_DIR/tunnel" && echo 'Session terminated by server' >"$MOCK_DIR/logs" ;;
    *) exit 3 ;;
    esac
    if [[ -f "$MOCK_DIR/logs" ]]; then
        echo stopped >"$MOCK_DIR/state"
    fi
    ;;
*) exit 2 ;;
esac
EOF

cat >"$TEST_ROOT/bin/openconnect" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"$MOCK_DIR/openconnect.calls"

case "$MOCK_AUTH" in
fail) exit 1 ;;
no_cookie) echo "HOST='fresh.example'" ;;
empty_pin) printf '%s\n' "COOKIE='fresh-cookie'" "FINGERPRINT='pin-sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='" ;;
*) printf '%s\n' "COOKIE='fresh-cookie'" "HOST='fresh.example'" "CONNECT_URL='https://fresh.example/'" \
    "FINGERPRINT='pin-sha256:fresh'" "RESOLVE='fresh.example:192.0.2.20'" ;;
esac
EOF
chmod +x "$TEST_ROOT/bin/container" "$TEST_ROOT/bin/openconnect" "$TEST_ROOT/guest/bin/timeout" "$TEST_ROOT/guest/bin/nslookup"

new_case() {
    CASE="$1"
    CASE_DIR="$TEST_ROOT/$CASE"
    SERVICE="$CASE_DIR/service.sh"
    MOCK_RUNS=""
    MOCK_AUTH=ok
    MOCK_NO_IMAGE=""
    MOCK_FAILS=""
    TRAFFIC_TIMEOUT=0
    STATE_HOME=state-home
    STATE_DIR="$STATE_HOME/anyconnect-proxy"
    COOKIE="$STATE_DIR/cookie"
    mkdir "$CASE_DIR"
    cp "$CODE_PATH/service.sh" "$SERVICE"
    cat >"$CASE_DIR/.env" <<EOF
ANYCONNECT_SERVER='$SERVER'
ANYCONNECT_CERT='pin-sha256:configured'
ANYCONNECT_RESOLVE='vpn.example:192.0.2.10'
ANYCONNECT_HOST='vpn.example'
ANYCONNECT_PASSWORD='unused'
EOF
}

cache_cookie() {
    mkdir -p "$CASE_DIR/$STATE_DIR"
    cat >"$CASE_DIR/$COOKIE" <<EOF
export ANYCONNECT_SERVER='$1'
export ANYCONNECT_CONNECT_URL='https://cached.example/'
export ANYCONNECT_HOST='cached.example'
export ANYCONNECT_CERT='pin-sha256:cached'
export ANYCONNECT_RESOLVE='cached.example:192.0.2.30'
export ANYCONNECT_COOKIE='cached-cookie'
EOF
}

# Takes the health of the running container: tunnel_down, no_traffic or ready.
container_running() {
    echo running >"$CASE_DIR/state"
    case "$1" in
    ready) touch "$CASE_DIR/tunnel" && cp "$TEST_ROOT/guest/nameservers" "$CASE_DIR/dns.replying" ;;
    no_traffic) touch "$CASE_DIR/tunnel" ;;
    esac
}

run_service() {
    STATUS=0
    env -u XDG_STATE_HOME ${STATE_HOME:+"XDG_STATE_HOME=$CASE_DIR/$STATE_HOME"} HOME="$CASE_DIR" \
        MOCK_DIR="$CASE_DIR" MOCK_COOKIE="$CASE_DIR/$COOKIE" MOCK_RUNS="$MOCK_RUNS" MOCK_AUTH="$MOCK_AUTH" \
        MOCK_NO_IMAGE="$MOCK_NO_IMAGE" MOCK_FAILS="$MOCK_FAILS" MOCK_GUEST="$TEST_ROOT/guest" PATH="$TEST_ROOT/bin:$PATH" \
        ANYCONNECT_READY_TIMEOUT=0 ANYCONNECT_TRAFFIC_TIMEOUT="$TRAFFIC_TIMEOUT" ANYCONNECT_POLL_INTERVAL=0 \
        "$SERVICE" "$@" >"$CASE_DIR/output" 2>&1 || STATUS=$?
}

fail() {
    echo "FAIL: $CASE: $*" >&2
    cat "$CASE_DIR/output" >&2
    exit 1
}

count_lines() {
    grep -c -- "$2" "$CASE_DIR/$1" 2>/dev/null || true
}

expect_status() {
    [[ "$STATUS" == "$1" ]] || fail "exit status $STATUS, expected $1"
}

expect_runs() {
    local runs
    runs="$(count_lines container.calls '^run ')"
    [[ "${runs:-0}" == "$1" ]] || fail "${runs:-0} container runs, expected $1"
}

# Every login must use only the configured values, never cached ones.
expect_logins() {
    local expected_args="${2:-$AUTH_ARGS}" logins
    logins="$(count_lines openconnect.calls .)"
    [[ "${logins:-0}" == "$1" ]] || fail "${logins:-0} logins, expected $1"
    [[ "$1" == 0 ]] || [[ "$(sort -u "$CASE_DIR/openconnect.calls")" == "$expected_args" ]] ||
        fail "unexpected login arguments: $(cat "$CASE_DIR/openconnect.calls")"
}

expect_call() {
    grep -q -- "$1" "$CASE_DIR/container.calls" || fail "no container call matching '$1'"
}

expect_no_call() {
    ! grep -q -- "$1" "$CASE_DIR/container.calls" 2>/dev/null || fail "unexpected container call matching '$1'"
}

expect_order() {
    local first second
    first="$(grep -n -m 1 -- "$1" "$CASE_DIR/container.calls" | cut -d: -f1)"
    second="$(grep -n -m 1 -- "$2" "$CASE_DIR/container.calls" | cut -d: -f1)"
    [[ -n "$first" && -n "$second" && "$first" -lt "$second" ]] || fail "no call matching '$1' before one matching '$2'"
}

expect_output() {
    grep -Fq -- "$1" "$CASE_DIR/output" || fail "output lacks '$1'"
}

expect_exact_output() {
    [[ "$(cat "$CASE_DIR/output")" == "$1" ]] || fail "output is not exactly '$1'"
}

expect_session() {
    local file="$CASE_DIR/$1" name="$2" expected="$3" actual
    actual="$(
        # shellcheck source=/dev/null
        source "$file"
        printf '%s' "${!name}"
    )" || fail "cannot read $name from $1"
    [[ "$actual" == "$expected" ]] || fail "$name in $1 is '$actual', expected '$expected'"
}

pass() {
    echo "PASS: $CASE"
}

new_case cached_cookie_via_symlink
cache_cookie "$SERVER"
mkdir "$CASE_DIR/link"
ln -s ../service.sh "$CASE_DIR/link/vpn"
SERVICE="$CASE_DIR/link/vpn"
MOCK_RUNS=ready
run_service connect
expect_status 0
expect_logins 0
expect_runs 1
expect_call "^run -d --name anyconnect --cpus 2 --memory 512M --cap-add NET_ADMIN --network default,mtu=1500 --kernel-arg sysctl.net.core.rmem_default=4194304 --mount type=bind,source=$CASE_DIR/$STATE_DIR,target=/run/anyconnect,readonly -p 127.0.0.1:1080:1080 --env PROXY_PORT=1080 --env VPN_RESOLV_CONF=/etc/resolv.vpn.conf --env ANYCONNECT_USERAGENT=$USERAGENT anyconnect:latest$"
expect_session run.1.cookie ANYCONNECT_COOKIE cached-cookie
expect_call '^ls$'
expect_no_call '^system '
pass

new_case system_not_running
cache_cookie "$SERVER"
MOCK_FAILS="ls"
MOCK_RUNS=ready
run_service connect
expect_status 0
expect_call '^system start$'
expect_order '^system start$' '^run '
expect_runs 1
pass

new_case default_state_home
STATE_HOME=""
STATE_DIR=.local/state/anyconnect-proxy
COOKIE="$STATE_DIR/cookie"
MOCK_RUNS=ready
run_service connect
expect_status 0
expect_runs 1
expect_call " --mount type=bind,source=$CASE_DIR/$STATE_DIR,target=/run/anyconnect,readonly "
expect_session "$COOKIE" ANYCONNECT_COOKIE fresh-cookie
expect_session run.1.cookie ANYCONNECT_COOKIE fresh-cookie
[[ "$(stat -f %Lp "$CASE_DIR/$STATE_DIR")" == 700 ]] || fail "state directory is not mode 700"
pass

new_case cache_for_other_server
cache_cookie other.example/SAML-EXT
MOCK_RUNS=ready
MOCK_AUTH=empty_pin
run_service connect
expect_status 0
expect_logins 1
expect_runs 1
expect_output "Ignoring the cached cookie for other.example/SAML-EXT"
expect_session run.1.cookie ANYCONNECT_SERVER "$SERVER"
expect_session run.1.cookie ANYCONNECT_COOKIE fresh-cookie
expect_session run.1.cookie ANYCONNECT_CERT pin-sha256:configured
expect_session run.1.cookie ANYCONNECT_HOST vpn.example
expect_session run.1.cookie ANYCONNECT_RESOLVE vpn.example:192.0.2.10
expect_session run.1.cookie ANYCONNECT_CONNECT_URL ""
[[ "$(stat -f %Lp "$CASE_DIR/$STATE_DIR")" == 700 ]] || fail "state directory is not mode 700"
[[ "$(stat -f %Lp "$CASE_DIR/$COOKIE")" == 600 ]] || fail "cookie is not mode 600"
pass

for rejection in rejected unauthorized pin no_traffic; do
    new_case "cached_session_$rejection"
    cache_cookie "$SERVER"
    MOCK_RUNS="$rejection ready"
    run_service connect
    expect_status 0
    expect_logins 1
    expect_runs 2
    expect_session run.1.cookie ANYCONNECT_COOKIE cached-cookie
    expect_session run.2.cookie ANYCONNECT_COOKIE fresh-cookie
    expect_session run.2.cookie ANYCONNECT_CERT pin-sha256:fresh
    expect_session run.2.cookie ANYCONNECT_HOST fresh.example
    expect_session run.2.cookie ANYCONNECT_CONNECT_URL https://fresh.example/
    expect_session run.2.cookie ANYCONNECT_RESOLVE fresh.example:192.0.2.20
    if [[ "$rejection" == no_traffic ]]; then
        expect_output "The tunnel carried no traffic for 0s."
        expect_output "The cached session carries no traffic; logging in again."
    fi
    pass
done

for failure in other hang exit_after_tunnel; do
    new_case "start_failure_$failure"
    cache_cookie "$SERVER"
    MOCK_RUNS="$failure"
    run_service connect
    expect_status 1
    expect_logins 0
    expect_runs 1
    expect_output "Container logs:"
    case "$failure" in
    other) expect_output "SSL connection failure" ;;
    hang) expect_output "not ready after 0s" ;;
    exit_after_tunnel) expect_output "Session terminated by server" ;;
    esac
    [[ "$failure" == hang ]] || expect_output "The VPN container exited."
    expect_session "$COOKIE" ANYCONNECT_COOKIE cached-cookie
    pass
done

for retry_failure in rejected no_traffic; do
    new_case "retry_also_$retry_failure"
    cache_cookie "$SERVER"
    MOCK_RUNS="$retry_failure $retry_failure"
    run_service connect
    expect_status 1
    expect_logins 1
    expect_runs 2
    pass
done

new_case first_nameserver_silent
cache_cookie "$SERVER"
MOCK_RUNS=first_dns_silent
run_service connect
expect_status 0
expect_logins 0
expect_runs 1
[[ "$(cat "$CASE_DIR/nslookup.calls")" == "$(cat "$TEST_ROOT/guest/nameservers")" ]] ||
    fail "the traffic check did not ask each nameserver in turn"
pass

new_case traffic_within_timeout
cache_cookie "$SERVER"
MOCK_RUNS=late_traffic
TRAFFIC_TIMEOUT=5
run_service connect
expect_status 0
expect_logins 0
expect_runs 1
pass

new_case fresh_login_no_traffic
MOCK_RUNS=no_traffic
run_service connect
expect_status 1
expect_logins 1
expect_runs 1
expect_output "The tunnel carried no traffic for 0s."
expect_output "Container logs:"
pass

new_case retry_login_fails
cache_cookie "$SERVER"
MOCK_RUNS=rejected
MOCK_AUTH=fail
run_service connect
expect_status 1
expect_logins 1
expect_runs 1
[[ ! -e "$CASE_DIR/$COOKIE" ]] || fail "rejected cookie kept"
pass

for login_failure in fail no_cookie; do
    new_case "login_$login_failure"
    MOCK_AUTH="$login_failure"
    run_service connect
    expect_status 1
    expect_logins 1
    expect_runs 0
    [[ ! -e "$CASE_DIR/$COOKIE" ]] || fail "cookie file written"
    pass
done

new_case already_ready
cache_cookie "$SERVER"
container_running ready
run_service connect
expect_status 0
expect_logins 0
expect_runs 0
expect_no_call '^stop '
expect_output "Already connected"
[[ "$(count_lines nslookup.calls .)" == 1 ]] || fail "the traffic check asked more than the first nameserver"
pass

for health in tunnel_down no_traffic; do
    new_case "running_$health"
    cache_cookie "$SERVER"
    container_running "$health"
    MOCK_RUNS=ready
    run_service connect
    expect_status 0
    expect_logins 0
    expect_runs 1
    expect_call "^stop --signal SIGHUP --time 20 anyconnect$"
    pass
done

status_case() {
    new_case "status_$1"
    if [[ "$1" == stopped ]]; then
        echo stopped >"$CASE_DIR/state"
    elif [[ "$1" != absent ]]; then
        container_running "$1"
    fi
    run_service status
    expect_status 0
    expect_exact_output "$2"
    pass
}

status_case absent "anyconnect: no container"
status_case stopped "anyconnect: stopped"
status_case tunnel_down "anyconnect: running, tunnel not up"
status_case no_traffic "anyconnect: running, tunnel up but carries no traffic"
status_case ready "anyconnect: running, tunnel ready"

new_case status_system_not_running
container_running ready
MOCK_FAILS="ls"
run_service status
expect_status 0
expect_exact_output "The container system service is not running."
expect_no_call '^system '
pass

for command in connect up start on; do
    new_case "$command"
    cache_cookie "$SERVER"
    MOCK_RUNS=ready
    run_service "$command"
    expect_status 0
    expect_no_call '^stop '
    expect_logins 0
    expect_runs 1
    pass
done

for command in disconnect down stop off; do
    new_case "$command"
    cache_cookie "$SERVER"
    container_running ready
    run_service "$command"
    expect_status 0
    expect_call "^stop --signal SIGHUP --time 20 anyconnect$"
    expect_call "^delete anyconnect$"
    expect_runs 0
    expect_session "$COOKIE" ANYCONNECT_COOKIE cached-cookie
    pass
done

for command in reconnect restart; do
    new_case "$command"
    cache_cookie "$SERVER"
    container_running ready
    MOCK_RUNS=ready
    run_service "$command"
    expect_status 0
    expect_call "^stop --signal SIGHUP --time 20 anyconnect$"
    expect_no_call "^stop --signal SIGTERM "
    expect_logins 0
    expect_runs 1
    pass
done

new_case logout
cache_cookie "$SERVER"
container_running ready
run_service logout
expect_status 0
expect_call "^stop --signal SIGTERM --time 20 anyconnect$"
expect_call "^delete anyconnect$"
expect_output "Logged out; no cached cookie remains."
[[ ! -e "$CASE_DIR/$COOKIE" ]] || fail "cookie file kept"
pass

new_case logout_not_running
cache_cookie "$SERVER"
run_service logout
expect_status 0
expect_no_call '^stop '
expect_output "The VPN was not running; no cached cookie remains."
[[ ! -e "$CASE_DIR/$COOKIE" ]] || fail "cookie file kept"
pass

for command in "" help -h --help; do
    new_case "usage${command:+_$command}"
    run_service ${command:+"$command"}
    expect_status 0
    expect_output "Usage:"
    [[ ! -e "$CASE_DIR/container.calls" ]] || fail "help called container"
    pass
done

new_case unknown_command
run_service bogus
expect_status 2
expect_output "Usage:"
pass

for action in reconnect rebuild; do
    new_case "${action}_invalid_config"
    echo "ANYCONNECT_SERVER='vpn.example'" >"$CASE_DIR/.env"
    cache_cookie "$SERVER"
    container_running ready
    run_service "$action"
    expect_status 1
    expect_no_call '^stop '
    expect_no_call '^delete '
    expect_no_call '^build '
    expect_logins 0
    expect_session "$COOKIE" ANYCONNECT_COOKIE cached-cookie
    pass
done

new_case no_pin_or_resolve
printf '%s\n' "ANYCONNECT_SERVER='$SERVER'" "ANYCONNECT_CERT=''" "ANYCONNECT_RESOLVE=''" >"$CASE_DIR/.env"
MOCK_RUNS=ready
run_service connect
expect_status 0
expect_logins 1 "--useragent $USERAGENT --authenticate $SERVER"
expect_runs 1
pass

new_case missing_image
cache_cookie "$SERVER"
MOCK_NO_IMAGE=1
MOCK_RUNS=ready
run_service connect
expect_status 0
expect_call "^build -t anyconnect:latest -f $CASE_DIR/Dockerfile $CASE_DIR$"
expect_order '^build ' '^builder stop$'
expect_order '^builder stop$' '^run '
pass

new_case missing_image_build_fails
cache_cookie "$SERVER"
MOCK_NO_IMAGE=1
MOCK_FAILS=build
run_service connect
expect_status 1
expect_no_call '^builder '
expect_runs 0
pass

new_case builder_stop_fails
cache_cookie "$SERVER"
MOCK_NO_IMAGE=1
MOCK_FAILS=builder
MOCK_RUNS=ready
run_service connect
expect_status 0
expect_output "Could not stop the image builder"
expect_runs 1
pass

new_case rebuild
cache_cookie "$SERVER"
container_running ready
MOCK_RUNS=ready
run_service rebuild
expect_status 0
expect_call "^build -t anyconnect:latest -f $CASE_DIR/Dockerfile $CASE_DIR$"
expect_order '^build ' '^builder stop$'
expect_order '^builder stop$' '^run '
expect_runs 1
pass
