FROM alpine:latest AS build
ARG ZIG_VERSION=0.15.2
ARG PUBLIC_KEY=RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U
RUN apk update && apk add build-base ffmpeg-dev tesseract-ocr-dev minisign
ADD https://zig.squirl.dev/zig-x86_64-linux-${ZIG_VERSION}.tar.xz /tmp
ADD https://zig.squirl.dev/zig-x86_64-linux-${ZIG_VERSION}.tar.xz.minisig /tmp

WORKDIR /tmp
RUN minisign -Vm zig-x86_64-linux-${ZIG_VERSION}.tar.xz -P "${PUBLIC_KEY}"

WORKDIR /usr/local
RUN tar xf /tmp/zig-x86_64-linux-${ZIG_VERSION}.tar.xz && \
    ln -s ./zig-x86_64-linux-${ZIG_VERSION} ./zig && \
    ln -s /usr/local/zig/zig bin/zig

WORKDIR /work
RUN apk add tesseract-ocr-data-eng

# WORKDIR /app
# RUN mkdir /tmp/zig-cache
# RUN --mount=type=bind,source=.,target=/app zig build --cache-dir /tmp/zig/cache -p /usr/local -Doptimize=ReleaseFast install

# FROM alpine:latest
# RUN apk add --no-cache ffmpeg-libs tesseract-ocr tesseract-ocr-data-eng
# COPY --from=build /usr/local/bin/dvdsub-tool /usr/local/bin/
# WORKDIR /work
# ENTRYPOINT ["/usr/local/bin/dvdsub-tool"]
