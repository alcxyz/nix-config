ARG BASE_APP_IMAGE=ghcr.io/games-on-whales/base-app@sha256:1d7b61da242e767bc5c80c5fe897392b6a9e6854345d3dea6d2f799e7ea98a14

FROM ${BASE_APP_IMAGE}

ARG BROWSER_EXECUTABLE
ARG BROWSER_FAMILY

COPY browser-store.tar /tmp/browser-store.tar

RUN set -eu; \
    tar --extract --file=/tmp/browser-store.tar --directory=/; \
    rm -f /tmp/browser-store.tar; \
    test -x "${BROWSER_EXECUTABLE}"

COPY --chmod=0755 startup.sh /opt/gow/startup-app.sh
COPY waybar.jsonc /cfg/waybar/config.jsonc
COPY waybar.css /cfg/waybar/style.css

ENV NIXBOX_BROWSER_EXECUTABLE=${BROWSER_EXECUTABLE}
ENV NIXBOX_BROWSER_FAMILY=${BROWSER_FAMILY}

ARG IMAGE_SOURCE
ARG IMAGE_VERSION
LABEL org.opencontainers.image.source=${IMAGE_SOURCE}
LABEL org.opencontainers.image.version=${IMAGE_VERSION}
LABEL org.nixbox.wolf-browser=true
