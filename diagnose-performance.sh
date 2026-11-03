#!/bin/bash

# Performance Diagnostics for Docker AnyConnect Proxy
# This script helps identify whether slow performance is due to VPN server or container issues

set -e

echo "=========================================="
echo "Docker AnyConnect Proxy Performance Diagnostics"
echo "=========================================="
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if containers are running
echo "1. Checking container status..."
if ! docker ps | grep -q "anyconnect_vpn"; then
    echo -e "${RED}ERROR: VPN container is not running${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Containers are running${NC}"
echo ""

# Test VPN connection inside container
echo "2. Testing VPN tunnel interface..."
docker exec anyconnect_vpn ifconfig tun0 2>/dev/null || echo -e "${RED}WARNING: tun0 interface not found${NC}"
echo ""

# Test network latency from host to VPN container
echo "3. Testing latency from host -> VPN container..."
CONTAINER_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' anyconnect_vpn)
if [ -n "$CONTAINER_IP" ]; then
    echo "Container IP: $CONTAINER_IP"
    ping -c 5 $CONTAINER_IP | tail -2
else
    echo -e "${YELLOW}Could not determine container IP${NC}"
fi
echo ""

# Test latency inside VPN container
echo "4. Testing latency inside VPN container (to 8.8.8.8)..."
docker exec anyconnect_vpn ping -c 5 8.8.8.8 | tail -2
echo ""

# Test latency through VPN tunnel to a real endpoint
echo "5. Testing latency through VPN to google.com..."
docker exec anyconnect_vpn ping -c 5 google.com 2>/dev/null | tail -2 || echo -e "${YELLOW}Could not ping google.com${NC}"
echo ""

# Check DNS resolution speed
echo "6. Testing DNS resolution speed inside VPN..."
time docker exec anyconnect_vpn nslookup google.com >/dev/null 2>&1 || echo -e "${YELLOW}DNS resolution failed${NC}"
echo ""

# Test download speed through VPN (direct)
echo "7. Testing download speed DIRECTLY in VPN container..."
docker exec anyconnect_vpn sh -c "time curl -s -o /dev/null -w 'Speed: %{speed_download} bytes/sec\nTime: %{time_total}s\n' https://speed.cloudflare.com/__down?bytes=10000000" 2>&1 | grep -E "(Speed|Time|real)"
echo ""

# Test download speed through SOCKS proxy
echo "8. Testing download speed through SOCKS PROXY (port 1080)..."
time curl -s -x socks5://localhost:1080 -o /dev/null -w 'Speed: %{speed_download} bytes/sec\nTime: %{time_total}s\n' https://speed.cloudflare.com/__down?bytes=10000000 2>&1 | grep -E "(Speed|Time|real)"
echo ""

# Test download speed through HTTP proxy
echo "9. Testing download speed through HTTP PROXY (port 1081)..."
time curl -s -x http://localhost:1081 -o /dev/null -w 'Speed: %{speed_download} bytes/sec\nTime: %{time_total}s\n' https://speed.cloudflare.com/__down?bytes=10000000 2>&1 | grep -E "(Speed|Time|real)"
echo ""

# Check CPU usage
echo "10. Checking container CPU and memory usage..."
docker stats --no-stream --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}" anyconnect_vpn anyconnect_proxy anyconnect_http_proxy
echo ""

# Check for packet loss
echo "11. Checking for packet loss in VPN container..."
docker exec anyconnect_vpn ping -c 20 8.8.8.8 | grep "packet loss"
echo ""

# Check VPN logs for issues
echo "12. Checking recent VPN container logs for errors..."
docker logs --tail 50 anyconnect_vpn 2>&1 | grep -i -E "(error|warning|timeout|failed|disconnect)" || echo -e "${GREEN}No obvious errors in logs${NC}"
echo ""

# Colima VM stats (if using colima)
echo "13. Checking Colima VM resource usage..."
if command -v colima &> /dev/null; then
    colima status || echo -e "${YELLOW}Colima not running or not accessible${NC}"
    echo ""
    echo "Colima VM stats:"
    colima ssh -- top -bn1 | head -20
else
    echo -e "${YELLOW}Colima CLI not found${NC}"
fi
echo ""

echo "=========================================="
echo "Diagnostic Summary"
echo "=========================================="
echo ""
echo "Compare the speeds from tests 7, 8, and 9:"
echo "  - Test 7 (direct in VPN): Baseline VPN server performance"
echo "  - Test 8 (SOCKS proxy): Adds SOCKS proxy overhead"
echo "  - Test 9 (HTTP proxy): Adds HTTP proxy overhead"
echo ""
echo "If all three are slow: VPN server is the bottleneck"
echo "If only 8 & 9 are slow: Proxy containers are the bottleneck"
echo "If latency is high (>100ms): Network/VPN server issue"
echo "If CPU is high: Container resource constraint"
echo ""
echo "Additional tips:"
echo "  - Check 'docker stats' for resource usage"
echo "  - Monitor with: docker logs -f anyconnect_vpn"
echo "  - Test without Colima to rule out VM overhead"
echo ""
