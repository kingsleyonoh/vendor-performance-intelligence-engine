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
    end

    teardown do
      Rails.logger = @previous_logger
      ENV.delete("AUDIT_ENABLED")
    end

    def last_audit_json
      tagged_line = @log_io.string.lines.map(&:chomp).find { |l| l.include?("[audit]") }
      refute_nil tagged_line, "expected a [audit]-tagged log line; captured: #{@log_io.string.inspect}"
      json = tagged_line.split("[audit]", 2).last.strip
      JSON.parse(json)
    end

    test "record emits a tagged JSON line with all canonical audit fields" do
      actor_class = Class.new do
        def self.name = "Tenant"
        attr_reader :id
        def initialize(id) = @id = id
      end
      actor = actor_class.new("actor-uuid-1")

      Audit::Recorder.record(
        actor: actor,
        action: "vendors#create",
        entity_type: "Vendor",
        entity_id: "vendor-uuid-1",
        before_state: nil,
        after_state: { "canonical_name" => "Acme" },
        tenant_id: "tenant-uuid-1"
      )

      payload = last_audit_json
      assert_equal "actor-uuid-1", payload["actor_id"]
      assert_equal "Tenant", payload["actor_type"]
      assert_equal "vendors#create", payload["action"]
      assert_equal "Vendor", payload["entity_type"]
      assert_equal "vendor-uuid-1", payload["entity_id"]
      assert_equal "tenant-uuid-1", payload["tenant_id"]
      assert_equal({ "canonical_name" => "Acme" }, payload["after_state"])
      assert_nil payload["before_state"]
      assert payload["occurred_at"].present?, "occurred_at must be populated with ISO8601 timestamp"
    end

    test "record falls back to Current.tenant.id when tenant_id is omitted" do
      Current.tenant = Struct.new(:id).new("current-tenant-1")

      Audit::Recorder.record(
        actor: Struct.new(:id).new("actor-x"),
        action: "vendors#update",
        entity_type: "Vendor",
        entity_id: "v-1"
      )

      assert_equal "current-tenant-1", last_audit_json["tenant_id"]
    ensure
      Current.tenant = nil
    end

    test "record serializes a non-id actor via to_s" do
      Audit::Recorder.record(
        actor: "system.cron",
        action: "jobs#run",
        entity_type: "ScoreRecomputeJob",
        entity_id: "job-1"
      )

      payload = last_audit_json
      assert_equal "system.cron", payload["actor_id"]
      assert_equal "String", payload["actor_type"]
    end

    test "record raises ArgumentError when actor is missing" do
      assert_raises(ArgumentError) do
        Audit::Recorder.record(
          actor: nil,
          action: "vendors#create",
          entity_type: "Vendor",
          entity_id: "v-1"
        )
      end
    end

    test "when AUDIT_ENABLED=false the recorder is a no-op" do
      ENV["AUDIT_ENABLED"] = "false"

      Audit::Recorder.record(
        actor: Struct.new(:id).new("actor-x"),
        action: "vendors#create",
        entity_type: "Vendor",
        entity_id: "v-1"
      )

      refute_match(/\[audit\]/, @log_io.string)
    end

    test "enabled? defaults to true when AUDIT_ENABLED is not set" do
      ENV.delete("AUDIT_ENABLED")
      assert Audit::Recorder.enabled?
    end

    test "enabled? returns false when AUDIT_ENABLED=false" do
      ENV["AUDIT_ENABLED"] = "false"
      refute Audit::Recorder.enabled?
    end
  end
end
