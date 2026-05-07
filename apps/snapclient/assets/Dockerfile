FROM debian:trixie-slim

ARG SNAPCLIENT_VERSION=0.34.0

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates wget \
 && ARCH=$(dpkg --print-architecture) \
 && wget -q "https://github.com/badaix/snapcast/releases/download/v${SNAPCLIENT_VERSION}/snapclient_${SNAPCLIENT_VERSION}-1_${ARCH}_trixie.deb" \
 && apt-get install -y --no-install-recommends ./snapclient_${SNAPCLIENT_VERSION}-1_${ARCH}.deb \
 && rm -f ./snapclient_*.deb \
 && rm -rf /var/lib/apt/lists/*

ENTRYPOINT ["/usr/bin/snapclient"]
