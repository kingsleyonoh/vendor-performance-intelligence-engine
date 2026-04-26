# frozen_string_literal: true

module Cache
  # Caches `api_key_prefix -> tenant_id` lookups so the `ApiKeyAuthenticator`
  # middleware (Phase 1) does not need to hit Postgres on every single API
  # request. 60-second TTL balances staleness (an API key rotation is visible
  # within a minute) against lookup-cost amortization on hot tenants.
  #
  # This is a STUB in Batch 005 — the interface is defined so the middleware
  # can call it the moment it lands in Phase 1. The middleware will:
  #
  #   cached = Cache::TenantCache.get(api_key_prefix)
  #   return cached if cached
  #   tenant = Tenant.find_by(api_key_prefix: api_key_prefix)
  #   ...verify key...
  #   Cache::TenantCache.set(api_key_prefix, tenant.id, ttl: 60)
  #
  # Invalidation on key rotation is the rotating controller's responsibility
  # (it calls `delete(api_key_prefix)` in the same DB transaction).
  class TenantCache
    NAMESPACE = :tenant_by_prefix
    DEFAULT_TTL_SECONDS = 60

    class << self
      def get(api_key_prefix)
        RequestCache.read(namespace: NAMESPACE, key: api_key_prefix)
      end

      def set(api_key_prefix, tenant_id, ttl: DEFAULT_TTL_SECONDS)
        RequestCache.write(namespace: NAMESPACE, key: api_key_prefix, value: tenant_id, ttl: ttl)
      end

      def delete(api_key_prefix)
        RequestCache.delete(namespace: NAMESPACE, key: api_key_prefix)
      end
    end
  end
end
