ARG BASE_APP_IMAGE=ghcr.io/games-on-whales/base-app@sha256:1d7b61da242e767bc5c80c5fe897392b6a9e6854345d3dea6d2f799e7ea98a14

FROM ${BASE_APP_IMAGE}

ARG BROWSER_EXECUTABLE
ARG BROWSER_FAMILY

ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

COPY browser-store.tar /tmp/browser-store.tar

RUN set -eu; \
    tar --extract --file=/tmp/browser-store.tar --directory=/; \
    rm -f /tmp/browser-store.tar; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      fonts-noto-color-emoji \
      fonts-noto-core \
      xinput; \
    rm -rf /var/lib/apt/lists/*; \
    fc-cache -f; \
    test "$(locale charmap)" = UTF-8; \
    fc-match -f '%{family}\n' 'Noto Color Emoji' | grep -F 'Noto Color Emoji'; \
    test -x "${BROWSER_EXECUTABLE}"

COPY --chmod=0755 startup.sh /opt/gow/startup-app.sh
COPY --chmod=0755 desktop-session.sh /opt/gow/desktop-session.sh
COPY --chmod=0755 kdeconnect-session.sh /opt/gow/kdeconnect-session.sh
COPY --chmod=0755 kde-pointer-bridge.py /opt/gow/kde-pointer-bridge.py
COPY waybar.jsonc /cfg/waybar/config.jsonc
COPY waybar.css /cfg/waybar/style.css

ENV NIXBOX_BROWSER_EXECUTABLE=${BROWSER_EXECUTABLE}
ENV NIXBOX_BROWSER_FAMILY=${BROWSER_FAMILY}

ARG IMAGE_SOURCE
ARG IMAGE_VERSION
LABEL org.opencontainers.image.source=${IMAGE_SOURCE}
LABEL org.opencontainers.image.version=${IMAGE_VERSION}
LABEL org.nixbox.wolf-browser=true
