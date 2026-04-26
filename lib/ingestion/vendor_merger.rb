# frozen_string_literal: true

module Ingestion
  # Ingestion::VendorMerger — PRD §5.2. Atomically collapses a duplicate
  # `source` vendor INTO a `target` vendor within a single tenant:
  #
  #   1. Reassign all vendor_aliases source → target.
  #   2. Reassign all vendor_signals source → target (the monthly partition
  #      key is `recorded_at`, not vendor_id — partitions stay intact).
  #      The model-layer + DB trigger normally block vendor_id change; the
  #      merger flips a session-scoped GUC + thread-local flag to unlock
  #      the UPDATE for this operation only.
  #   3. Stamp source.status = 'merged' with metadata.{merge_into, merged_at}.
  #   4. Fire `on_merge_hooks` — Phase 2 wires risk_alerts re-parent here.
  #   5. Everything runs in a single DB transaction for atomicity.
  #
  # Returns a counts hash `{ aliases_moved:, signals_moved: }`.
  #
  # Tenant isolation: both vendors MUST belong to the same tenant, passed in
  # explicitly; callers that accept vendor IDs from untrusted input must
  # pre-validate via `Vendor.where(tenant_id: ...).find(id)`.
  class VendorMerger
    class AlreadyMerged < StandardError; end
    class SameVendor < StandardError; end
    class CrossTenant < StandardError; end

    # Class-level on_merge hooks. Each is a proc invoked with keyword args
    # `(source:, target:)` after the merge transaction commits. Phase 2
    # registers a risk_alerts-reparent hook here without monkey-patching.
    class << self
      def on_merge_hooks
        @on_merge_hooks ||= []
      end
    end

    def self.call(tenant:, source:, target:)
      new(tenant: tenant, source: source, target: target).call
    end

    def initialize(tenant:, source:, target:)
      @tenant = tenant
      @source = source
      @target = target
    end

    def call
      validate!

      counts = { aliases_moved: 0, signals_moved: 0 }

      ActiveRecord::Base.transaction do
        counts[:aliases_moved] = reassign_aliases
        counts[:signals_moved] = reassign_signals
        mark_source_merged
      end

      fire_on_merge_hooks

      counts
    end

    private

    def validate!
      raise SameVendor, "source and target must differ" if @source.id == @target.id
      raise CrossTenant, "source tenant mismatch" if @source.tenant_id != @tenant.id
      raise CrossTenant, "target tenant mismatch" if @target.tenant_id != @tenant.id
      raise AlreadyMerged, "source already merged" if @source.status == "merged"
      raise AlreadyMerged, "target already merged" if @target.status == "merged"
    end

    def reassign_aliases
      VendorAlias.where(tenant_id: @tenant.id, vendor_id: @source.id)
                 .update_all(vendor_id: @target.id, updated_at: Time.now.utc)
    end

    # Reassigns vendor_signals source → target. The DB trigger normally
    # blocks vendor_id UPDATE; we temporarily flip the session GUC +
    # thread-local flag so the trigger permits it for this transaction.
    #
    # Partition key is `recorded_at` (not vendor_id), so rows remain in
    # the same monthly partition after the UPDATE — verified by test.
    def reassign_signals
      moved = 0
      VendorSignal.with_merge_mode do
        ActiveRecord::Base.connection.execute(
          "SELECT set_config('vpi.signals_merge_mode', 'true', true)"
        )
        moved = VendorSignal
                  .where(tenant_id: @tenant.id, vendor_id: @source.id)
                  .update_all(vendor_id: @target.id, merged_at: Time.now.utc)
      end
      moved
    end

    def mark_source_merged
      updated_metadata = (@source.metadata || {}).merge(
        "merge_into" => @target.id,
        "merged_at" => Time.now.utc.iso8601
      )
      @source.update!(status: "merged", metadata: updated_metadata)
    end

    def fire_on_merge_hooks
      self.class.on_merge_hooks.each do |hook|
        hook.call(source: @source, target: @target)
      rescue StandardError => e
        Rails.logger.error("[vendor_merger] on_merge hook failed: #{e.class}: #{e.message}")
      end
    end
  end
end
