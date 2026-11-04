# AGENTS.md

Guidance for coding agents working on this repository. `README.md` is the
user-facing reference; this file records how the project works inside, and the
lessons learned while building it.

## What it does

`service.sh` runs on a Mac. It logs in to a Cisco AnyConnect gateway with SAML
in the browser (`openconnect --authenticate` against a `/SAML-EXT` URL), saves
the session cookie, and starts one Apple `container` named `anyconnect`. The
container runs:

- `openconnect`, started from the saved cookie by `entrypoint.sh`;
- a `dnsmasq` DNS cache, started by the `post-connect` hook;
- a SOCKS5 proxy (`/socks5` from `serjs/go-socks5-proxy`), started by
  `entrypoint.sh` and published on `127.0.0.1:1080`.

Only traffic sent through the proxy uses the VPN.

## Files

| File | Role | Needs `rebuild` |
| --- | --- | --- |
| `service.sh` | Host commands, login, health checks, container settings | No |
| `entrypoint.sh` | Container process 1: starts the proxy, then supervises `openconnect` | Yes |
| `post-connect.sh` | `vpnc-script` hook: DNS cache and `resolv.conf` | Yes |
| `restart-openconnect.sh` | `vpnc-script` hook: turns a reconnect into a restart | Yes |
| `Dockerfile`, `.dockerignore` | Image; `.dockerignore` is an allow-list | Yes |
| `tests/service-test.sh` | Host tests with mocked `container` and `openconnect` | No |

The cookie lives in `${XDG_STATE_HOME:-~/.local/state}/anyconnect-proxy/cookie`
(mode 600) and is mounted read-only at `/run/anyconnect`.

## Sessions and reconnects

- The gateway uses Cisco STRAP. The saved cookie includes a private key
  (`openconnect_strapkey=`). When `openconnect` reconnects inside a running
  process, it sends the gateway a new public key and keeps the new private key
  only in memory. The saved cookie then gets `401` in any new process.
- A fresh `openconnect` started from the saved cookie keeps the original key.
  So `openconnect` must never reconnect in place: the `attempt-reconnect` hook
  writes a restart marker and sends SIGHUP, and `entrypoint.sh` starts a new
  `openconnect`.
- `openconnect` sets no timeout on the TLS handshake or the `CONNECT` request.
  After a Mac sleep these can hang forever, so each start must create `tun0`
  within 10 seconds, or the loop restarts it.
- After a restart, a start that fails at once (exit status 1, for example while
  the network is down) is retried every 10 seconds. Status 2 means the gateway
  rejected the cookie; that ends the container, and `service.sh` logs in again.
- A reconnect can get `200 OK` and still carry no traffic. `status` and
  `connect` therefore send a DNS lookup straight to the VPN nameservers.
- Gateway limits seen so far: session 7 days, 16 hours disconnected, DPD 30 s,
  keepalive 20 s.

## openconnect signals

| Signal | Effect |
| --- | --- |
| SIGHUP | Disconnects and keeps the session. Used by `disconnect` and for restarts. |
| SIGTERM, SIGINT | Logs the session out. Used by `logout`. |
| SIGUSR2 | Reconnects in place, which replaces the STRAP key. Do not use it. |

`entrypoint.sh` forwards HUP, INT and TERM to `openconnect`, then exits without
restarting.

## Quirks

- **Inherited descriptors.** Processes started from `vpnc-script` hooks
  inherit `openconnect`'s `/dev/net/tun` descriptor. Anything long-lived must
  start outside `openconnect`, or `tun0` outlives `openconnect` and the next
  start creates `tun1`. `dnsmasq` closes inherited descriptors itself.
- **Hooks** are sourced by `vpnc-script` under busybox `ash`. Never call
  `exit` in a hook, and never block.
- **Busybox:** `nslookup` has no timeout option, and prints `Server:` only when
  a reply arrives. `pidof` also matches finished (zombie) processes, so check
  listening ports instead.
- **DNS cache:** once `resolv.conf` points at `127.0.0.1`, do not copy it to
  the `dnsmasq` resolv file, or `dnsmasq` forwards to itself.
- **Apple `container`:**
  - Each container is a small VM without vhost-net. The default UDP receive
    buffer drops packets, so `service.sh` sets `net.core.rmem_default` to
    4 MiB with `--kernel-arg`. That plus an MTU of 1500 (set with `--network`)
    raised downloads from about 0.5 MB/s to 2 MB/s.
  - There is no restart policy and no Compose.
  - `container system status` can report the service as stopped while it
    works; use `container ls`.
  - `container cp` drops the executable bit.
  - The image builder VM keeps running after a build; `service.sh` stops it.
- **Rejected alternatives:** Colima broke and was slower to manage; `ocproxy`
  is limited to about 0.5 MB/s per connection by its fixed 64 KB TCP window.

## Testing

- Run `bash tests/service-test.sh` and `shellcheck` on changed shell files.
- Test container logic in a throwaway container from the built image, with a
  name other than `anyconnect` and a stub `openconnect`.
- Live tests cost logins if done carelessly. Replacing the container needs a
  valid saved cookie. Simulate a hung gateway inside the container with
  `iptables`: accept SYN-ACK from the gateway and drop its other packets.
- `container` commands must run outside an agent's command sandbox.

## Safety

- Never read or print `.env` values or the cookie file.
- Never run `openconnect` with `--dump-http-traffic` on the real session; it
  logs the cookie.
- `logout`, SIGTERM and SIGINT end the session and force a browser login.
