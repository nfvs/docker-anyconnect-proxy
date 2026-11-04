# shellcheck shell=sh
# vpnc-script sources this file after it has set routes and DNS, so the DNS cache
# starts only once the tunnel is configured. Never call exit here.
# service.sh sets VPN_RESOLV_CONF in the container's environment.

DNS_CACHE_ADDRESS=127.0.0.1

# Once resolv.conf points at the cache, copying it would make dnsmasq forward to itself.
grep -qxF "nameserver $DNS_CACHE_ADDRESS" /etc/resolv.conf || cp /etc/resolv.conf "$VPN_RESOLV_CONF"

if netstat -lnu | grep -qF "$DNS_CACHE_ADDRESS:53 " ||
    dnsmasq --listen-address="$DNS_CACHE_ADDRESS" --bind-interfaces \
        --resolv-file="$VPN_RESOLV_CONF" --cache-size=1000 --no-hosts --log-facility=-; then
    {
        grep -v '^nameserver' "$VPN_RESOLV_CONF"
        echo "nameserver $DNS_CACHE_ADDRESS"
    } >/etc/resolv.conf
fi
