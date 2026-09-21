# syntax=docker/dockerfile:1

ARG RUBY_VERSION=4.0.7
ARG NODE_VERSION=26.9.0

FROM node:${NODE_VERSION}-trixie-slim AS node
FROM ruby:${RUBY_VERSION}-slim-trixie

# Node.js を公式イメージからそのまま持ち込む（バージョンを厳密に固定するため）
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
 && ln -s /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx

RUN apt-get update -qq \
 && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      curl \
      git \
      libpq-dev \
      libyaml-dev \
      pkg-config \
      postgresql-client \
 && rm -rf /var/lib/apt/lists/*

ENV LANG=C.UTF-8 \
    TZ=Asia/Tokyo \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_JOBS=4

WORKDIR /app

EXPOSE 3000
CMD ["bash"]
