# syntax=docker/dockerfile:1.12

# This file is designed for production server deployment, not local development work
# For a containerized local dev environment, see: https://github.com/mastodon/mastodon/blob/main/docs/DEVELOPMENT.md#docker

# Please see https://docs.docker.com/engine/reference/builder for information about
# the extended buildx capabilities used in this file.
# Make sure multiarch TARGETPLATFORM is available for interpolation
# See: https://docs.docker.com/build/building/multi-platform/
# syntax=docker/dockerfile:1.12
# This Dockerfile builds the Bubbles (Mastodon fork) production image.
# IMPORTANT: Enable BuildKit (DOCKER_BUILDKIT=1) when building.

# Build arguments and base images
ARG TARGETPLATFORM=${TARGETPLATFORM}
ARG BUILDPLATFORM=${BUILDPLATFORM}
ARG BASE_REGISTRY="docker.io"

ARG RUBY_VERSION="3.4.2"
ARG NODE_MAJOR_VERSION="22"
ARG DEBIAN_VERSION="bookworm"
ARG MASTODON_VERSION_PRERELEASE=""
ARG MASTODON_VERSION_METADATA=""
ARG SOURCE_COMMIT=""
ARG RAILS_SERVE_STATIC_FILES="true"
ARG RUBY_YJIT_ENABLE="1"
ARG TZ="Etc/UTC"
ARG UID="991"
ARG GID="991"

# Stage: Node (for Node-based tools)
FROM ${BASE_REGISTRY}/node:${NODE_MAJOR_VERSION}-${DEBIAN_VERSION}-slim AS node

# Stage: Ruby base image
FROM ${BASE_REGISTRY}/ruby:${RUBY_VERSION}-slim-${DEBIAN_VERSION} AS ruby

# Set environment variables
ENV \
  MASTODON_VERSION_PRERELEASE="${MASTODON_VERSION_PRERELEASE}" \
  MASTODON_VERSION_METADATA="${MASTODON_VERSION_METADATA}" \
  SOURCE_COMMIT="${SOURCE_COMMIT}" \
  RAILS_SERVE_STATIC_FILES=${RAILS_SERVE_STATIC_FILES} \
  RUBY_YJIT_ENABLE=${RUBY_YJIT_ENABLE} \
  TZ=${TZ} \
  BIND="0.0.0.0" \
  NODE_ENV="production" \
  RAILS_ENV="production" \
  DEBIAN_FRONTEND="noninteractive" \
  PATH="${PATH}:/opt/ruby/bin:/opt/mastodon/bin" \
  MALLOC_CONF="narenas:2,background_thread:true,thp:never,dirty_decay_ms:1000,muzzy_decay_ms:0" \
  MASTODON_USE_LIBVIPS=true \
  MASTODON_SIDEKIQ_READY_FILENAME=sidekiq_process_has_started_and_will_begin_processing_jobs

SHELL ["/bin/bash", "-o", "pipefail", "-o", "errexit", "-c"]

ARG TARGETPLATFORM
RUN echo "Target platform is $TARGETPLATFORM"

# Create mastodon user and symlink
RUN \
  rm -f /etc/apt/apt.conf.d/docker-clean; \
  echo "${TZ}" > /etc/localtime; \
  groupadd -g "${GID}" mastodon; \
  useradd -l -u "${UID}" -g "${GID}" -m -d /opt/mastodon mastodon; \
  ln -s /opt/mastodon /mastodon;

WORKDIR /opt/mastodon

# Install system dependencies with BuildKit caching
RUN \
  --mount=type=cache,id=apt-cache-${TARGETPLATFORM},target=/var/cache/apt,sharing=locked \
  --mount=type=cache,id=apt-lib-${TARGETPLATFORM},target=/var/lib/apt,sharing=locked \
  apt-get update; \
  apt-get dist-upgrade -yq; \
  apt-get install -y --no-install-recommends \
    curl file libjemalloc2 patchelf procps tini tzdata wget; \
  patchelf --add-needed libjemalloc.so.2 /usr/local/bin/ruby; \
  apt-get purge -y patchelf;

# ------------------------------------------------------------------------------------
# (The remaining intermediate stages for building assets, compiling libvips, ffmpeg,
# bundler, yarn, and precompiling assets remain unchanged.)
#
# For brevity, only the final production stage is shown below.
# ------------------------------------------------------------------------------------

FROM ruby AS mastodon

ARG TARGETPLATFORM
RUN \
  --mount=type=cache,id=apt-cache-${TARGETPLATFORM},target=/var/cache/apt,sharing=locked \
  --mount=type=cache,id=apt-lib-${TARGETPLATFORM},target=/var/lib/apt,sharing=locked \
  --mount=type=cache,id=corepack-cache-${TARGETPLATFORM},target=/usr/local/share/.cache/corepack,sharing=locked \
  --mount=type=cache,id=yarn-cache-${TARGETPLATFORM},target=/usr/local/share/.cache/yarn,sharing=locked \
  apt-get install -y --no-install-recommends \
    libexpat1 libglib2.0-0 libicu72 libidn12 libpq5 libreadline8 libssl3 libyaml-0-2 \
    libcgif0 libexif12 libheif1 libimagequant0 libjpeg62-turbo liblcms2-2 liborc-0.4-0 \
    libspng0 libtiff6 libwebp7 libwebpdemux2 libwebpmux3 libdav1d6 libmp3lame0 \
    libopencore-amrnb0 libopencore-amrwb0 libopus0 libsnappy1v5 libtheora0 libvorbis0a \
    libvorbisenc2 libvorbisfile3 libvpx7 libx264-164 libx265-199;
COPY . /opt/mastodon/
COPY --from=precompiler /opt/mastodon/public/packs /opt/mastodon/public/packs
COPY --from=precompiler /opt/mastodon/public/assets /opt/mastodon/public/assets
COPY --from=bundler /usr/local/bundle/ /usr/local/bundle/
COPY --from=libvips /usr/local/libvips/bin /usr/local/bin
COPY --from=libvips /usr/local/libvips/lib /usr/local/lib
COPY --from=ffmpeg /usr/local/ffmpeg/bin /usr/local/bin
COPY --from=ffmpeg /usr/local/ffmpeg/lib /usr/local/lib

RUN ldconfig; \
    vips -v; \
    ffmpeg -version; \
    ffprobe -version;

RUN bundle exec bootsnap precompile --gemfile app/ lib/;
RUN mkdir -p /opt/mastodon/public/system; \
    chown mastodon:mastodon /opt/mastodon/public/system; \
    chown -R mastodon:mastodon /opt/mastodon/tmp;

USER mastodon
EXPOSE 3000
ENTRYPOINT ["/usr/bin/tini", "--"]
