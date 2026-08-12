# syntax=docker/dockerfile:1

ARG BUILD_IMAGE=ghcr.io/games-on-whales/gstreamer:1.26.7@sha256:930e2513a514308f60bf04e0264a3320a9f5605de66f99844ec283d8084e1689
ARG RUNTIME_IMAGE=ghcr.io/games-on-whales/wolf@sha256:8515dd1a88fa6c4a39a814c7c2f7eee4106d5b60c8140be6d0ef689324a079a2

FROM ${BUILD_IMAGE} AS wolf-builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
      build-essential ca-certificates ccache clang cmake git ninja-build pkg-config \
      libboost-container-dev libboost-filesystem-dev libboost-json-dev \
      libboost-locale-dev libboost-log-dev libboost-stacktrace-dev libboost-thread-dev \
      libcurl4-openssl-dev libdrm-dev libegl-dev libevdev-dev libgbm-dev \
      libgles-dev libglib2.0-dev libinput-dev libopengl-dev libpci-dev \
      libpulse-dev libssl-dev libudev-dev libunwind-dev \
      libwayland-dev libwayland-server0 libxkbcommon-dev && \
    rm -rf /var/lib/apt/lists/*

COPY . /wolf/
WORKDIR /wolf

RUN --mount=type=cache,target=/cache/ccache \
    cmake -B/cache/cmake-build \
      -DCMAKE_BUILD_TYPE=RelWithDebInfo \
      -DCMAKE_CXX_STANDARD=20 \
      -DCMAKE_CXX_EXTENSIONS=OFF \
      -DCMAKE_CXX_FLAGS="-Wno-missing-template-arg-list-after-template-kw" \
      -DBUILD_SHARED_LIBS=OFF \
      -DBoost_USE_STATIC_LIBS=ON \
      -DBUILD_FAKE_UDEV_CLI=ON \
      -DBUILD_TESTING=OFF \
      -G Ninja && \
    ninja -C /cache/cmake-build wolf && \
    cp /cache/cmake-build/src/moonlight-server/wolf /wolf/wolf-patched

FROM ${RUNTIME_IMAGE}

COPY --from=wolf-builder /wolf/wolf-patched /wolf/wolf
