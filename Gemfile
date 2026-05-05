source "https://rubygems.org"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.0.5"
# The modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem "propshaft"
# Use postgresql as the database for Active Record
gem "pg", "~> 1.1"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Use JavaScript with ESM import maps [https://github.com/rails/importmap-rails]
gem "importmap-rails"
# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem "turbo-rails"
# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem "stimulus-rails"
# Use Tailwind CSS [https://github.com/rails/tailwindcss-rails]
gem "tailwindcss-rails"
# Build JSON APIs with ease [https://github.com/rails/jbuilder]
gem "jbuilder"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
gem "bcrypt", "~> 3.1.7"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Use the database-backed adapters for Rails.cache, Active Job, and Action Cable
gem "solid_cache"
gem "solid_queue"
gem "solid_cable"

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", require: false

# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
# gem "image_processing", "~> 1.2"

# ---------------------------------------------------------------------------
# VPI-specific dependencies (PRD §3, §13.1)
# ---------------------------------------------------------------------------

# Background jobs — Sidekiq 7 (PRD §3, §7)
gem "sidekiq", "~> 7.3"

# Cron scheduling for Sidekiq (PRD §7 — PartitionManagerJob + others)
gem "sidekiq-cron", "~> 1.12"

# HTTP clients — Faraday 2 singletons for ecosystem adapters (PRD §6, §9)
gem "faraday", "~> 2.9"
gem "faraday-retry", "~> 2.2"

# Serialization — Alba (PRD §3)
gem "alba", "~> 3.5"

# Authorization — ActionPolicy (PRD §3, tenant-scoped policies)
gem "action_policy", "~> 0.7"

# Validation for non-model inputs — dry-validation (PRD §3, ingestion payloads)
gem "dry-validation", "~> 1.10"

# Messaging — NATS JetStream (Contract Lifecycle subscriber, feature-flagged)
gem "nats-pure", "~> 2.5"

# PDF generation — WickedPDF for vendor scorecards (PRD §3, §5.6)
gem "wicked_pdf", "~> 2.7"
gem "wkhtmltopdf-binary", "~> 0.12"

# Rate limiting — Rack::Attack (PRD §8b, §10b)
gem "rack-attack", "~> 6.7"

# CORS — browser preflight for `/api/*` (driven by ALLOWED_ORIGINS env, PRD §14)
gem "rack-cors", "~> 2.0"

# Redis client — backs Rack::Attack's RedisCacheStore (PRD §10b). Note that
# sidekiq ships redis-client but `ActiveSupport::Cache::RedisCacheStore`
# specifically needs the full `redis` gem.
gem "redis", "~> 5.3"

# Structured logging — Lograge → Axiom JSON (PRD §10b)
gem "lograge", "~> 0.14"

# Error tracking — Sentry (PRD §10b; DSN wired in Phase 3)
gem "sentry-ruby", "~> 5.21"
gem "sentry-rails", "~> 5.21"

# Prometheus metrics — `/metrics` endpoint scraped by self-hosted Prometheus
# (PRD §10b). Pure-Ruby exposition format; Basic Auth gated by
# METRICS_BASIC_AUTH_USER/PASS. Disabled when PROMETHEUS_ENABLED=false.
gem "prometheus-client", "~> 4.2"

# Product analytics — PostHog (self-hosted). Five instrumented events per
# PRD §10b: vendor_viewed, alert_acknowledged, scoring_rule_activated,
# report_generated, api_key_rotated. No-op when POSTHOG_API_KEY unset.
gem "posthog-ruby", "~> 3.8"

# View components — ViewComponent for PDF + UI rendering (PRD §3, §9)
gem "view_component", "~> 3.18"

# Levenshtein distance for vendor alias fuzzy-match (PRD §5.2 rung 3).
# Ruby stdlib doesn't ship an edit-distance implementation; this gem gives
# us `Text::Levenshtein.distance(a, b)` with a pure-Ruby fallback.
gem "text", "~> 1.3"

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false

  # Load .env.local + .env during dev/test (docker-compose injects env directly,
  # but this keeps `bin/rails console` + rake tasks working without it).
  gem "dotenv-rails", "~> 3.1"
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"
end

group :test do
  # Liquid template engine — used by template-binding fixture tests to
  # render Hub templates against representative DeliveryPayloads under
  # strict-undefined mode (PRD §13.2 + §15 #14). Hub-side templating
  # uses Liquid; the project ships local copies of the registered
  # templates as fixtures so CI fails on any unmapped token.
  gem "liquid", "~> 5.5"

  # PDF text extraction — used by report-generator tests to assert no
  # cross-tenant leakage in generated PDFs (PRD §15 #15). wkhtmltopdf
  # FlateDecode-compresses content streams, so a raw byte grep cannot
  # see the rendered text. pdf-reader inflates streams + decodes fonts.
  gem "pdf-reader", "~> 2.12"

  # Use system testing [https://guides.rubyonrails.org/testing.html#system-testing]
  gem "capybara"
  gem "selenium-webdriver"

  # Playwright driver for Capybara (used by test:system per PRD §3 testing stack)
  gem "capybara-playwright-driver", "~> 0.5"
  gem "playwright-ruby-client", "~> 1.47"

  # VCR + WebMock for ecosystem HTTP fixtures (PRD §6, §15 — fixture-backed
  # integration tests are MANDATORY for every adapter).
  gem "vcr", "~> 6.3"
  gem "webmock", "~> 3.23"
end
