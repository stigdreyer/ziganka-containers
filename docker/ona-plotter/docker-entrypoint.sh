#!/bin/sh
set -eu

: "${SIGNALK_URL:=http://halos.local:3000}"
: "${APP_PORT:=8090}"

# OnaPlotter's WASM reads /appsettings.json at boot. Rewrite on every
# container start so a config change in HaLOS takes effect on restart.
cat > /usr/share/nginx/html/appsettings.json <<EOF
{
  "SignalK": { "ServerUrl": "${SIGNALK_URL}" }
}
EOF

envsubst '${APP_PORT}' < /etc/nginx/nginx.conf.tpl > /etc/nginx/nginx.conf

exec nginx -g 'daemon off;'
