# frozen_string_literal: true

module Api
  # Health check endpoints — PRD §8, §8b, §10b. Public (no `X-API-Key`
  # required); paths allowlisted in `Auth::ApiKeyAuthenticator::PUBLIC_ALLOWLIST_PATHS`.
  #
  #   GET /api/health       → liveness: returns 200 as long as the Rails app
  #                            accepts HTTP. Used by BetterStack + load balancers.
  #   GET /api/health/db    → Postgres reachable? 200 / 503.
  #   GET /api/health/redis → Redis reachable? 200 / 503.
  #   GET /api/health/ready → aggregate readiness across db + redis + sidekiq.
  #
  # Inherits `ActionController::API` directly (NOT `Api::BaseController`) so
  # the tenant-authentication before_action does not run here — health checks
  # are unauthenticated.
  #
  # Probes are pluggable class attributes so tests can inject failure modes
  # without reaching into Postgres/Redis clients directly.
  class HealthController < ActionController::API
    SIDEKIQ_QUEUE_DEPTH_THRESHOLD = 1000

    class << self
      attr_accessor :db_probe, :redis_probe, :sidekiq_probe

      def reset_probes_for_test!
        self.db_probe = default_db_probe
        self.redis_probe = default_redis_probe
        self.sidekiq_probe = default_sidekiq_probe
      end

      def default_db_probe
        -> { ActiveRecord::Base.connection.execute("SELECT 1") }
      end

      def default_redis_probe
        -> { ::Sidekiq.redis { |c| c.call("PING") } }
      end

      def default_sidekiq_probe
        lambda do
          require "sidekiq/api"
          stats = ::Sidekiq::Stats.new
          largest = ::Sidekiq::Queue.all.map(&:size).max || 0
          { processed: stats.processed, queue_depth: largest }
        end
      end
    end

    # Install defaults once at class load so production callers never hit
    # a nil probe. Tests call `reset_probes_for_test!` in teardown.
    self.db_probe      = default_db_probe
    self.redis_probe   = default_redis_probe
    self.sidekiq_probe = default_sidekiq_probe

    def index
      render json: {
        status: "ok",
        service: "vpi",
        version: version_string,
        checked_at: Time.now.utc.iso8601
      }, status: :ok
    end

    def db
      probe_component("db", self.class.db_probe)
    end

    def redis
      probe_component("redis", self.class.redis_probe)
    end

    def ready
      db_state, db_err         = call_probe(self.class.db_probe)
      redis_state, redis_err   = call_probe(self.class.redis_probe)
      sidekiq_state, sk_err    = call_sidekiq_probe

      all_ok = [db_state, redis_state, sidekiq_state].all? { |s| s == "ok" }

      body = {
        status: all_ok ? "ok" : "unavailable",
        components: {
          "db" => db_state,
          "redis" => redis_state,
          "sidekiq" => sidekiq_state
        },
        details: {
          "db" => db_err,
          "redis" => redis_err,
          "sidekiq" => sk_err
        }.compact,
        checked_at: Time.now.utc.iso8601
      }
      render json: body, status: all_ok ? :ok : :service_unavailable
    end

    private

    def probe_component(name, probe)
      state, err = call_probe(probe)
      if state == "ok"
        render json: { status: "ok", component: name, checked_at: Time.now.utc.iso8601 }, status: :ok
      else
        render json: {
          status: "unavailable",
          component: name,
          details: { name => err },
          checked_at: Time.now.utc.iso8601
        }, status: :service_unavailable
      end
    end

    # Runs a probe proc. Returns ["ok", nil] on success,
    # ["error", <exception message>] on failure.
    def call_probe(probe)
      return ["error", "probe not configured"] if probe.nil?

      probe.call
      ["ok", nil]
    rescue StandardError => e
      Rails.logger.warn("[health] probe failed: #{e.class}: #{e.message}")
      ["error", "#{e.class}: #{e.message}"]
    end

    # Sidekiq is additionally threshold-checked: a live Redis with a
    # runaway queue is still "not ready". Any raise during the probe or
    # a queue over the threshold counts as "error".
    def call_sidekiq_probe
      probe = self.class.sidekiq_probe
      return ["error", "probe not configured"] if probe.nil?

      result = probe.call
      depth = result.is_a?(Hash) ? result[:queue_depth].to_i : 0
      if depth > SIDEKIQ_QUEUE_DEPTH_THRESHOLD
        ["error", "sidekiq queue depth #{depth} exceeds #{SIDEKIQ_QUEUE_DEPTH_THRESHOLD}"]
      else
        ["ok", nil]
      end
    rescue StandardError => e
      Rails.logger.warn("[health] sidekiq probe failed: #{e.class}: #{e.message}")
      ["error", "#{e.class}: #{e.message}"]
    end

    def version_string
      Rails.application.config.x.version || ENV.fetch("VPI_VERSION", "dev")
    end
  end
end
