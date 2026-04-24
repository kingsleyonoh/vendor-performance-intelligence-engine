require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Vpi
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.0

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # ActiveJob → Sidekiq 7 (PRD §3, §7). VPI opts OUT of Solid Queue because
    # Sidekiq is the canonical queue for the ecosystem + matches the 15-job
    # table in `.claude/rules/CODEBASE_CONTEXT_MODULES.md`.
    config.active_job.queue_adapter = :sidekiq

    # Rate limiting — Rack::Attack baseline throttle (PRD §8b / §10b).
    # Initializer at `config/initializers/rack_attack.rb` configures the store
    # + the one `req/ip` baseline rule. Middleware must be registered here so
    # it wraps the full stack (not only routed endpoints).
    config.middleware.use Rack::Attack
  end
end
