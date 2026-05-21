worker_processes auto;
error_log /dev/stderr warn;
pid /tmp/nginx.pid;

events {
  worker_connections 1024;
}

http {
  include       /etc/nginx/mime.types;
  default_type  application/octet-stream;
  types {
    application/wasm wasm;
  }

  sendfile on;
  tcp_nopush on;
  keepalive_timeout 65;

  gzip on;
  gzip_static on;
  gzip_types text/plain text/css application/javascript application/json application/wasm image/svg+xml;

  access_log /dev/stdout;

  client_body_temp_path /tmp/client_body;
  proxy_temp_path       /tmp/proxy;
  fastcgi_temp_path     /tmp/fastcgi;
  uwsgi_temp_path       /tmp/uwsgi;
  scgi_temp_path        /tmp/scgi;

  server {
    listen ${APP_PORT};
    server_name _;
    root /usr/share/nginx/html;
    index index.html;

    location / {
      try_files $uri $uri/ /index.html;
    }

    location = /appsettings.json {
      add_header Cache-Control "no-store" always;
    }

    location ~* \.(?:wasm|dll|dat|blat|js|css|woff2?|svg|png|webp|json)$ {
      access_log off;
      expires 7d;
      add_header Cache-Control "public, max-age=604800, immutable";
    }
  }
}
