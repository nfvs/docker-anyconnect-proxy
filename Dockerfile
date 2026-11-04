FROM alpine:3.21

RUN apk add --no-cache bash dnsmasq openconnect \
    && wget -O /etc/vpnc/vpnc-script https://gitlab.com/openconnect/vpnc-scripts/raw/master/vpnc-script \
    && chmod +x /etc/vpnc/vpnc-script

COPY --from=serjs/go-socks5-proxy /socks5 /socks5
COPY post-connect.sh /etc/vpnc/post-connect.d/
COPY restart-openconnect.sh /etc/vpnc/attempt-reconnect.d/
COPY entrypoint.sh /entrypoint.sh

CMD ["/entrypoint.sh"]
