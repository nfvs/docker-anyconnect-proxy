FROM alpine:3.21
RUN apk add bash openconnect ca-certificates tzdata --no-cache
RUN wget https://gitlab.com/openconnect/vpnc-scripts/raw/master/vpnc-script -O /etc/vpnc/vpnc-script && \
    chmod +x /etc/vpnc/vpnc-script
COPY entrypoint.sh /entrypoint.sh
HEALTHCHECK  --interval=10s --timeout=10s --start-period=10s \
  CMD /sbin/ifconfig tun0
CMD ["/entrypoint.sh"]
