# frozen_string_literal: true

require "test_helper"

module Audit
  class RecorderTest < ActiveSupport::TestCase
    setup do
      @log_io = StringIO.new
      @previous_logger = Rails.logger
      logger = Logger.new(@log_io)
      logger.formatter = ->(_severity, _time, _progname, msg) { "#{msg}\n" }
      Rails.logger = ActiveSupport::TaggedLogging.new(logger)
      @tenant = tenants(:acme_gmbh_de)
    end

    teardown do
      Rails.logger = @previous_logger
      ENV.delete("AUDIT_ENABLED")
      ENV.delete("AUDIT_DB_WRITES")
      Current.tenant = nil if Current.respond_to?(:tenant=)
    end

    def last_audit_json
      tagged_line = @log_io.string.lines.map(&:chomp).find { |l| l.include?("[audit]") }
      refute_nil tagged_line, "expected a [audit]-tagged log line; captured: #{@log_io.string.inspect}"
      json = tagged_line.split("[audit]", 2).last.strip
      JSON.parse(json)
    end

    # ------------------------------------------------------------------
    # DB path (preferred — Phase 3 default)
    # ------------------------------------------------------------------
    test "DB path: record inserts an audit_log_entries row with all canonical fields" do
      actor_class = Class.new do
        def self.name = "Tenant"
        attr_reader :id
        def initialize(id) = @id = id
      end
      actor = actor_class.new("actor-uuid-1")

      assert_difference -> { AuditLogEntry.count }, 1 do
        Audit::Recorder.record(
          actor: actor,
          action: "vendors#create",
          entity_type: "Vendor",
          entity_id: "vendor-uuid-1",
          before_state: nil,
          after_state: { "canonical_name" => "Acme" },
          tenant_id: @tenant.id
        )
      end

      row = AuditLogEntry.order(occurred_at: :desc).first
      assert_equal "actor-uuid-1", row.actor_id
      assert_equal "Tenant", row.actor_type
      assert_equal "vendors#create", row.action
      assert_equal "Vendor", row.entity_type
      assert_equal "vendor-uuid-1", row.entity_id
      assert_equal @tenant.id, row.tenant_id
      assert_equal({ "canonical_name" => "Acme" }, row.after_state)
      assert_nil row.before_state
    end

    test "DB path: falls back to Current.tenant.id when tenant_id is omitted" do
      Current.tenant = @tenant
      assert_difference -> { AuditLogEntry.count }, 1 do
        Audit::Recorder.record(
          actor: Struct.new(:id).new("actor-x"),
          action: "vendors#update",
          entity_type: "Vendor",
          entity_id: "v-1"
        )
      end

      row = AuditLogEntry.order(occurred_at: :desc).first
      assert_equal @tenant.id, row.tenant_id
    end

    test "DB path: serializes a non-id actor via to_s" do
      Audit::Recorder.record(
        actor: "system.cron",
        action: "jobs#run",
        entity_type: "ScoreRecomputeJob",
        entity_id: "job-1",
        tenant_id: @tenant.id
      )

      row = AuditLogEntry.order(occurred_at: :desc).first
      assert_equal "system.cron", row.actor_id
      assert_equal "String", row.actor_type
    end

    test "DB path: metadata kwarg is merged into stored row" do
      Audit::Recorder.record(
        actor: "system.cron",
        action: "vendors#create",
        entity_type: "Vendor",
        entity_id: "v-1",
        tenant_id: @tenant.id,
        metadata: { ip: "10.0.0.1", user_agent: "curl/8" }
      )

      row = AuditLogEntry.order(occurred_at: :desc).first
      assert_equal "10.0.0.1", row.metadata["ip"]
      assert_equal "curl/8", row.metadata["user_agent"]
    end

    # ------------------------------------------------------------------
    # Fallback path (DB unavailable / explicitly disabled)
    # ------------------------------------------------------------------
    test "fallback path: AUDIT_DB_WRITES=false routes to tagged log line" do
      ENV["AUDIT_DB_WRITES"] = "false"

      assert_no_difference -> { AuditLogEntry.count } do
        Audit::Recorder.record(
          actor: Struct.new(:id).new("actor-fallback"),
          action: "vendors#create",
          entity_type: "Vendor",
          entity_id: "v-1",
          tenant_id: @tenant.id
        )
      end

      payload = last_audit_json
      assert_equal "actor-fallback", payload["actor_id"]
      assert_equal "vendors#create", payload["action"]
      assert payload["occurred_at"].present?
    end

    # ------------------------------------------------------------------
    # Disabled
    # ------------------------------------------------------------------
    test "AUDIT_ENABLED=false short-circuits both paths (no DB row, no log line)" do
      ENV["AUDIT_ENABLED"] = "false"

      assert_no_difference -> { AuditLogEntry.count } do
        Audit::Recorder.record(
          actor: Struct.new(:id).new("actor-x"),
          action: "vendors#create",
          entity_type: "Vendor",
          entity_id: "v-1",
          tenant_id: @tenant.id
        )
      end

      refute_match(/\[audit\]/, @log_io.string)
    end

    # ------------------------------------------------------------------
    # Required-actor guard
    # ------------------------------------------------------------------
    test "raises ArgumentError when actor is missing" do
      assert_raises(ArgumentError) do
        Audit::Recorder.record(
          actor: nil,
          action: "vendors#create",
          entity_type: "Vendor",
          entity_id: "v-1"
        )
      end
    end

    # ------------------------------------------------------------------
    # Predicates
    # ------------------------------------------------------------------
    test "enabled? defaults to true when AUDIT_ENABLED is not set" do
      ENV.delete("AUDIT_ENABLED")
      assert Audit::Recorder.enabled?
    end

    test "enabled? returns false when AUDIT_ENABLED=false" do
      ENV["AUDIT_ENABLED"] = "false"
      refute Audit::Recorder.enabled?
    end

    test "db_writes_disabled? respects AUDIT_DB_WRITES" do
      ENV["AUDIT_DB_WRITES"] = "false"
      assert Audit::Recorder.db_writes_disabled?
      ENV.delete("AUDIT_DB_WRITES")
      refute Audit::Recorder.db_writes_disabled?
    end
  end
end
