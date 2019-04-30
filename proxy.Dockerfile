FROM alpine:latest
COPY --from=serjs/go-socks5-proxy /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs
COPY --from=serjs/go-socks5-proxy /socks5 /
ENTRYPOINT ["/socks5"]
