FROM alpine:3.20
RUN apk add bash openconnect --no-cache
RUN ln -s /usr/libexec/openconnect/csd-wrapper.sh /root/.csd-wrapper.sh
ADD entrypoint.sh /entrypoint.sh
HEALTHCHECK  --interval=10s --timeout=10s --start-period=10s \
  CMD /sbin/ifconfig tun0
CMD ["/entrypoint.sh"]
