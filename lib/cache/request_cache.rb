# frozen_string_literal: true

module Cache
  # Generic namespaced memoization wrapper around `Rails.cache`.
  #
  # Every VPI cache key lives under the `vpi:<namespace>:<key>` prefix so
  # operators can scan / flush specific concerns (`vpi:tenant_by_prefix:*`,
  # `vpi:scoring_config:*`) without nuking the whole Redis keyspace. The
  # backing store is whatever the current Rails environment configures:
  #
  # - production: Redis (configured alongside Rack::Attack in Batch 003)
  # - development: `:memory_store` (config/environments/development.rb)
  # - test:       `:null_store` by default — cache tests swap in a real
  #   `ActiveSupport::Cache::MemoryStore` in setup so contract behavior
  #   is observable.
  #
  # See `.agent/knowledge/foundation/cache-helpers.md` for the three-tier
  # convention (request-cache -> tenant-cache -> scoring-config-cache).
  class RequestCache
    KEY_PREFIX = "vpi"

    class << self
      # Read-through fetch. On miss, invokes the block, caches the result
      # with `expires_in: ttl`, and returns the value. On hit, returns the
      # cached value without invoking the block.
      def fetch(namespace:, key:, ttl:, &block)
        raise ArgumentError, "block required" unless block

        Rails.cache.fetch(build_key(namespace: namespace, key: key), expires_in: ttl, &block)
      end

      def read(namespace:, key:)
        Rails.cache.read(build_key(namespace: namespace, key: key))
      end

      def write(namespace:, key:, value:, ttl:)
        Rails.cache.write(build_key(namespace: namespace, key: key), value, expires_in: ttl)
      end

      def delete(namespace:, key:)
        Rails.cache.delete(build_key(namespace: namespace, key: key))
      end

      # Public for testability + for callers that need to pre-compute a key
      # (e.g. for atomic write-then-read sequences).
      def build_key(namespace:, key:)
        "#{KEY_PREFIX}:#{namespace}:#{key}"
      end
    end
  end
end
