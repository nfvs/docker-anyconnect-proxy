FROM alpine:3.21
RUN apk add bash openconnect --no-cache
RUN wget --no-check-certificate https://gist.github.com/l0ki000/56845c00fd2a0e76d688/raw/61fc41ac8aec53ae0f9f0dfbfa858c1740307de4/csd-wrapper.sh -O "/root/.csd-wrapper.sh"
# RUN ln -s /usr/libexec/openconnect/csd-wrapper.sh /root/.csd-wrapper.sh
RUN wget https://gitlab.com/openconnect/vpnc-scripts/raw/master/vpnc-script -O /etc/vpnc/vpnc-script && \
    chmod +x /etc/vpnc/vpnc-script
ADD entrypoint.sh /entrypoint.sh
HEALTHCHECK  --interval=10s --timeout=10s --start-period=10s \
  CMD /sbin/ifconfig tun0
CMD ["/entrypoint.sh"]
