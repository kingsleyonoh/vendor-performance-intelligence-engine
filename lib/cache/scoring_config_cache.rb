# frozen_string_literal: true

module Cache
  # Caches the active `scoring_rules` row (category weights, band thresholds,
  # time-decay half-life, signal overrides) per tenant so each
  # `ScoreRecomputeJob` / preview endpoint does not hit Postgres for config
  # on every vendor. 5-minute TTL is long enough to amortize cost on bulk
  # rescore batches and short enough that a config change is visible inside
  # one dashboard refresh.
  #
  # This is a STUB surface in Batch 005. The Phase 1 scoring pipeline will:
  #
  #   config = Cache::ScoringConfigCache.fetch_for(tenant_id) do
  #     ScoringRule.where(tenant_id: tenant_id, is_active: true).sole.as_config
  #   end
  #
  # Invalidation: the `scoring_rules` controller calls `.invalidate(tenant_id)`
  # inside the same transaction as the write, so the next read falls through
  # to the DB.
  class ScoringConfigCache
    NAMESPACE = :scoring_config
    TTL_SECONDS = 300

    class << self
      def fetch_for(tenant_id, &block)
        raise ArgumentError, "tenant_id required" if tenant_id.nil? || tenant_id.to_s.strip.empty?
        raise ArgumentError, "block required" unless block

        RequestCache.fetch(
          namespace: NAMESPACE,
          key: "tenant:#{tenant_id}",
          ttl: TTL_SECONDS,
          &block
        )
      end

      def invalidate(tenant_id)
        RequestCache.delete(namespace: NAMESPACE, key: "tenant:#{tenant_id}")
      end
    end
  end
end
