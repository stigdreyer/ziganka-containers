#!/bin/sh
set -e

# Wait for Docker to finish attaching all bridge networks to containers.
sleep 8

# Discover all UP bridge interfaces (br-* covers all compose-created bridges;
# docker0 is the default bridge). We reflect mDNS between every bridge and
# eth0 so Spotify Connect is visible regardless of which bridge librespot
# inside Music Assistant happens to use.
BRIDGES=$(ip -o link show up | awk -F': ' '{print $2}' | grep -E '^(br-|docker[0-9])' | tr '\n' ' ')

if [ -z "$BRIDGES" ]; then
    echo "ERROR: no Docker bridge interfaces found" >&2
    exit 1
fi

echo "mdns-repeater: reflecting mDNS between eth0 and [ ${BRIDGES}]"
exec /usr/local/bin/mdns-repeater -f eth0 ${BRIDGES}
