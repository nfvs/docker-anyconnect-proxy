# Configuring
Create `.env` file with the following parameters:
```sh
ANYCONNECT_SERVER=
ANYCONNECT_USER=
ANYCONNECT_GROUP=
ANYCONNECT_PASSWORD=
```

`ANYCONNECT_SERVER` is the configured SAML endpoint, such as
`vpn.example.com/SAML-EXT`. OpenConnect may return a separate VPN connect URL;
the service caches that internally for cookie reuse.

# Running
```sh
$ ./service.sh up
```

# Proxy settings

Configure clients to use the SOCKS5 proxy:

```text
Host: vpn
Port: 1080
Type: SOCKS5
```

For tools that accept proxy URLs, prefer `socks5h://` so corp DNS names are
resolved through the VPN proxy:

```sh
export ALL_PROXY=socks5h://vpn:1080
curl --proxy socks5h://vpn:1080 https://corp-host
```

The HTTP proxy is disabled by default. Re-enable the commented `http_proxy`
service in `docker-compose.yml` only for tools that cannot use SOCKS5.

# macOS Colima tuning

Use native Apple Silicon virtualization and give the default Colima VM a
reachable IP:

```sh
colima stop
colima start \
  --cpu 2 \
  --memory 2 \
  --network-address \
  --network-mode shared \
  --vm-type vz \
  --arch aarch64 \
  --runtime docker \
  --save-config
```

Get the VM IP and add it to `/etc/hosts` as `vpn`:

```sh
colima list
```
