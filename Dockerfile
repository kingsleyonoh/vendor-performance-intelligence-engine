# syntax=docker/dockerfile:1.6
# Vendor Performance Intelligence Engine — Rails 8.0 / Ruby 3.3 production image
# Multi-stage: builder compiles gems + assets; runtime is a lean Ruby slim image.

# ---------------------------------------------------------------------------
# Stage 1: Builder
# ---------------------------------------------------------------------------
FROM ruby:3.3-slim AS builder

ENV BUNDLE_DEPLOYMENT=1 \
    BUNDLE_WITHOUT=development:test \
    BUNDLE_PATH=/usr/local/bundle \
    RAILS_ENV=production \
    NODE_ENV=production \
    LANG=C.UTF-8

# Build-time dependencies. Rails 8 + Tailwind CSS ships via `tailwindcss-rails`
# (pure-Ruby wrapper around the tailwindcss binary) + importmap-rails for JS —
# no Node/npm required.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      build-essential \
      ca-certificates \
      curl \
      git \
      libpq-dev \
      libvips \
      libyaml-dev \
      pkg-config && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install gems first so Docker can cache the bundle layer.
COPY Gemfile Gemfile.lock ./
RUN bundle config set --local deployment 'true' && \
    bundle config set --local without 'development test' && \
    bundle install --jobs 4 --retry 3 && \
    rm -rf /usr/local/bundle/cache/*.gem && \
    find /usr/local/bundle -name "*.o" -delete && \
    find /usr/local/bundle -name "*.c" -delete

# Copy the app and precompile assets. SECRET_KEY_BASE is a throwaway for asset compilation.
COPY . .
RUN SECRET_KEY_BASE=precompile-placeholder \
    RAILS_ENV=production \
    bundle exec rails assets:precompile && \
    rm -rf tmp/cache test spec

# ---------------------------------------------------------------------------
# Stage 2: Runtime
# ---------------------------------------------------------------------------
FROM ruby:3.3-slim AS production

ENV BUNDLE_DEPLOYMENT=1 \
    BUNDLE_WITHOUT=development:test \
    BUNDLE_PATH=/usr/local/bundle \
    RAILS_ENV=production \
    RAILS_LOG_TO_STDOUT=1 \
    RAILS_SERVE_STATIC_FILES=1 \
    LANG=C.UTF-8 \
    PORT=3000

# Runtime-only libs: libpq5 (PG driver), libvips42 (ActiveStorage), tini
# (PID 1 signal handling), curl (healthcheck). WickedPDF / wkhtmltopdf
# lands in Phase 3 when the reporting engine is wired (PRD §5.6, §13.3) —
# the Debian 12 repos no longer ship wkhtmltopdf, so Phase 3 will fetch
# a static wkhtmltopdf binary instead.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      ca-certificates \
      curl \
      libpq5 \
      libvips42 \
      libyaml-0-2 \
      tini \
      tzdata && \
    rm -rf /var/lib/apt/lists/*

# Non-root user.
RUN groupadd --system --gid 1000 rails && \
    useradd  --system --uid 1000 --gid rails --create-home --shell /bin/bash rails

WORKDIR /app

# Copy gems + app from builder.
COPY --from=builder --chown=rails:rails /usr/local/bundle /usr/local/bundle
COPY --from=builder --chown=rails:rails /app /app

# Reports directory (mounted as a volume in docker-compose).
RUN mkdir -p /var/vpi/reports && chown -R rails:rails /var/vpi/reports

USER rails:rails

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD curl --fail --silent http://localhost:3000/api/health/ready || exit 1

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["bin/rails", "server", "-b", "0.0.0.0", "-p", "3000"]
