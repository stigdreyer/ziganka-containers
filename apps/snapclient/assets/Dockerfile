FROM debian:trixie-slim

ARG SNAPCLIENT_VERSION=0.35.0

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates wget \
 && ARCH=$(dpkg --print-architecture) \
 && wget -q "https://github.com/badaix/snapcast/releases/download/v${SNAPCLIENT_VERSION}/snapclient_${SNAPCLIENT_VERSION}-1_${ARCH}_trixie.deb" \
 && apt-get install -y --no-install-recommends ./snapclient_${SNAPCLIENT_VERSION}-1_${ARCH}_trixie.deb \
 && rm -f ./snapclient_*.deb \
 && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
