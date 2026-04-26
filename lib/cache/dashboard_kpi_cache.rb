# frozen_string_literal: true

module Cache
  # Caches dashboard KPI aggregates per tenant for 5 minutes (PRD §10b).
  # Each KPI surface (`band_counts`, `status_counts`, etc.) lives under its
  # own slot keyed by `(tenant_id, kpi_name)`, so different KPIs never share
  # a cache entry and a single tenant's invalidation does not nuke siblings.
  #
  # Layout:
  #   key:        vpi:dashboard:kpi:<tenant_id>:<kpi_name>
  #   index_key:  vpi:dashboard:kpi:index:<tenant_id> -> Set<String> (kpi names)
  #
  # The index key is what makes per-tenant invalidation O(1) without a
  # SCAN against Redis (which would be expensive at scale and is not even
  # available through `Rails.cache.delete_matched` on every store
  # implementation). On `fetch_for`, we add the kpi_name to the index;
  # on `invalidate(tenant_id)`, we delete every kpi listed in the index
  # plus the index itself.
  #
  # See `.agent/knowledge/foundation/cache-helpers.md` for the three-tier
  # convention (RequestCache -> TenantCache -> ScoringConfigCache, and
  # now DashboardKpiCache as the fourth tier).
  class DashboardKpiCache
    NAMESPACE       = :"dashboard:kpi"
    INDEX_NAMESPACE = :"dashboard:kpi:index"
    TTL_SECONDS     = 300

    class << self
      # Read-through fetch. On miss, invokes the block, stores the value
      # under `(tenant_id, kpi_name)` for `TTL_SECONDS`, and registers the
      # kpi_name in the per-tenant index so `invalidate(tenant_id)` can
      # later drop every slot.
      def fetch_for(tenant_id:, kpi_name:, &block)
        raise ArgumentError, "tenant_id required" if tenant_id.nil? || tenant_id.to_s.empty?
        raise ArgumentError, "kpi_name required" if kpi_name.nil? || kpi_name.to_s.empty?
        raise ArgumentError, "block required" unless block

        key = composite_key(tenant_id, kpi_name)
        cached = RequestCache.read(namespace: NAMESPACE, key: key)
        return cached unless cached.nil?

        value = block.call
        RequestCache.write(namespace: NAMESPACE, key: key, value: value, ttl: TTL_SECONDS)
        register_kpi_in_index(tenant_id, kpi_name)
        value
      end

      # Drops every cached KPI for `tenant_id`. Used by the SignalIngester
      # post-insert hook (see `config/initializers/signal_ingester_hooks.rb`)
      # so the dashboard reflects fresh signals within one render cycle.
      def invalidate(tenant_id:)
        return if tenant_id.nil? || tenant_id.to_s.empty?

        index = RequestCache.read(namespace: INDEX_NAMESPACE, key: tenant_id.to_s) || []
        index.each do |kpi_name|
          RequestCache.delete(namespace: NAMESPACE, key: composite_key(tenant_id, kpi_name))
        end
        RequestCache.delete(namespace: INDEX_NAMESPACE, key: tenant_id.to_s)
      end

      private

      def composite_key(tenant_id, kpi_name)
        "#{tenant_id}:#{kpi_name}"
      end

      def register_kpi_in_index(tenant_id, kpi_name)
        index = RequestCache.read(namespace: INDEX_NAMESPACE, key: tenant_id.to_s) || []
        return if index.include?(kpi_name.to_s)

        index << kpi_name.to_s
        # Index TTL is 1.5x the slot TTL — long enough to survive one
        # invalidation cycle, short enough to self-heal if a process
        # exits between writing the index and writing the value.
        RequestCache.write(
          namespace: INDEX_NAMESPACE,
          key: tenant_id.to_s,
          value: index,
          ttl: (TTL_SECONDS * 1.5).to_i
        )
      end
    end
  end
end
