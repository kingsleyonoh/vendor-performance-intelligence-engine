# Sidekiq 7 — Redis wiring for both server + client processes.
#
# VPI uses Sidekiq (NOT Solid Queue) for:
#   - ScoreRecomputeJob + AllVendorsRescoreJob (PRD §7)
#   - Ecosystem backfill jobs (PRD §6, §7)
#   - HubDispatchJob + WorkflowEscalationJob (PRD §5.5)
#   - ReportGeneratorJob + ExpiredReportReaperJob (PRD §5.6)
#   - PartitionManagerJob (PRD §4.5, partman rollover)
#
# Redis URL resolves to the compose service name `redis:6379` in dev/test,
# and to REDIS_URL in production (set via the VPS secret store).

redis_config = {
  url: ENV.fetch("REDIS_URL", "redis://redis:6379/0"),
}

Sidekiq.configure_server do |config|
  config.redis = redis_config

  # Load cron schedule on Sidekiq server boot. The sidekiq-cron gem
  # registers each entry in Redis; restarting workers re-applies the file.
  # Loaded only in the server process (not the client) because clients don't
  # own the scheduler loop.
  config.on(:startup) do
    schedule_path = Rails.root.join("config", "schedule.yml")
    if schedule_path.exist? && defined?(Sidekiq::Cron::Job)
      schedule = YAML.load_file(schedule_path) || {}
      ::Sidekiq::Cron::Job.load_from_hash!(schedule) if schedule.any?
    end
  end
end

Sidekiq.configure_client do |config|
  config.redis = redis_config
end
