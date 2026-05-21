# Two-stage build: compile the Blazor WASM bundle, then ship it from
# a tiny nginx. The .NET 10 SDK is only needed for the build; the
# runtime image is plain static files.

ARG ONA_PLOTTER_REPO=https://github.com/msallin/ona-plotter
ARG ONA_PLOTTER_SHA

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
ARG ONA_PLOTTER_REPO
ARG ONA_PLOTTER_SHA
RUN test -n "$ONA_PLOTTER_SHA" || (echo "ONA_PLOTTER_SHA build arg is required" && exit 1)

WORKDIR /src
RUN git init -q . \
 && git remote add origin "$ONA_PLOTTER_REPO" \
 && git fetch --depth 1 origin "$ONA_PLOTTER_SHA" \
 && git checkout -q FETCH_HEAD

RUN dotnet publish -c Release OnaPlotter/OnaPlotter.csproj -o /publish

FROM nginx:1.27-alpine
RUN apk add --no-cache gettext wget

COPY --from=build /publish/wwwroot/ /usr/share/nginx/html/
COPY nginx.conf.tpl /etc/nginx/nginx.conf.tpl
COPY docker-entrypoint.sh /docker-entrypoint-onaplotter.sh
RUN chmod +x /docker-entrypoint-onaplotter.sh

ENV APP_PORT=8090 \
    SIGNALK_URL=http://halos.local:3000

ENTRYPOINT ["/docker-entrypoint-onaplotter.sh"]
