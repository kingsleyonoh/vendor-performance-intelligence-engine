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
end

Sidekiq.configure_client do |config|
  config.redis = redis_config
end
