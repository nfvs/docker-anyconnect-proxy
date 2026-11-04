# AnyConnect SOCKS5 proxy

This project connects to a Cisco AnyConnect VPN that uses SAML login. It runs
`openconnect` in a Linux container and offers a SOCKS5 proxy on your Mac. Only
traffic that you send through the proxy uses the VPN.

You log in on the Mac, in your browser. The container then reuses the session
cookie from that login.

# Requirements

- A Mac with Apple silicon and macOS 26.
- Apple's `container` runtime and `openconnect`:

```sh
brew install container openconnect
container system start --enable-kernel-install
```

# Configuration

Copy `.env.example` to `.env` beside `service.sh` and fill in the values:

| Key | Required | Meaning |
| --- | --- | --- |
| `ANYCONNECT_SERVER` | Yes | SAML login URL. It must end in `/SAML-EXT`, for example `vpn.example.com/SAML-EXT`. |
| `ANYCONNECT_CERT` | No | Certificate pin of the gateway, such as `pin-sha256:...`. The login checks it. |
| `ANYCONNECT_RESOLVE` | No | `host:ip` pair for `openconnect --resolve`. |
| `ANYCONNECT_HOST` | No | VPN host to use when the login does not return one. |
| `ANYCONNECT_CONNECT_URL` | No | VPN URL to use when the login does not return one. |
| `ANYCONNECT_USERAGENT` | No | User agent. The default is `AnyConnect-compatible OpenConnect VPN Agent`. |

# Usage

```sh
./service.sh connect
```

You can also link `service.sh` into a directory on your `PATH`.

| Command | Aliases | What it does | VPN session |
| --- | --- | --- | --- |
| `connect` | `up`, `start`, `on` | Starts the VPN. It reuses the cached session or opens the browser to log in. It does nothing if the VPN is already connected. | Kept or created |
| `disconnect` | `down`, `stop`, `off` | Stops the VPN. | Kept |
| `reconnect` | `restart` | Runs `disconnect`, then `connect`. It does not rebuild the image. | Kept |
| `rebuild` | | Rebuilds the image, then reconnects. Use it after you change `Dockerfile`, `entrypoint.sh`, `post-connect.sh` or `restart-openconnect.sh`. | Kept |
| `logout` | | Logs out if the VPN is running, stops it and deletes the cookie. | Ended |
| `status` | | Shows whether the container runs, the tunnel is up and it carries traffic. | |
| `logs` | | Shows the container logs. Extra arguments go to `container logs`, for example `-f`. | |
| `help` | `-h`, `--help` | Shows the commands. It is the default when you give no command. | |

To start over with a new login, run `logout`, then `connect`.

The session cookie is stored in `$XDG_STATE_HOME/anyconnect-proxy/cookie`, by
default `~/.local/state/anyconnect-proxy/cookie`. Only your user can read it.
The container gets it as a read-only file.

`connect` and `status` test the tunnel with a DNS query to the VPN's DNS
servers. When `connect` starts with the cached cookie, it logs in once more and
starts again if the gateway rejects the cookie, its certificate no longer
matches the pin, or the tunnel carries no traffic within 10 seconds of coming
up. Any other error stops `connect` and prints the container logs.

When the tunnel drops, for example while the Mac sleeps, the container starts
`openconnect` again from the saved session instead of letting it reconnect in
place, so the saved login stays valid until the session ends. A start that has
not connected within 10 seconds is replaced by a new one. After such a restart,
a start that fails, for example because the network is still down, is tried
again every 10 seconds unless the gateway rejects the session.

While the tunnel is down, for example during a restart or while the gateway does
not answer, the proxy connects directly through your Mac's network instead of
the VPN. Hosts that only the VPN can resolve fail during that time. `status`
shows whether the tunnel is up.

The container boots with a larger UDP receive buffer and an MTU of 1500, which
makes the VPN faster. It also caches DNS answers, so repeated lookups of a host
name skip the VPN until the answer expires.

# Proxy settings

The SOCKS5 proxy listens on `127.0.0.1:1080`. Use `socks5h://` so that host
names are resolved through the VPN:

```sh
curl --proxy socks5h://127.0.0.1:1080 https://intranet.example.com
export ALL_PROXY=socks5h://127.0.0.1:1080
```

To keep using the host name `vpn` for the proxy, add this line to `/etc/hosts`:

```text
127.0.0.1 vpn
```

# Tests

```sh
tests/service-test.sh
```

The test replaces `container` and `openconnect` with mocks. It does not contact
the VPN.
