# shellcheck shell=sh
# vpnc-script sources this file before each attempt to reconnect in place. Such a reconnect gives the gateway a new
# STRAP key that only this openconnect process knows, so the saved cookie would stop working. SIGHUP makes openconnect
# exit without logging out, and entrypoint.sh then starts a new one from the saved cookie. Never call exit here.

echo "Starting a new openconnect instead of reconnecting in place." >&2
touch "$RESTART_MARKER"
kill -HUP "$VPNPID"
