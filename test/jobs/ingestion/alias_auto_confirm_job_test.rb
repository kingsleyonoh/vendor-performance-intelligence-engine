require "test_helper"

# Ingestion::AliasAutoConfirmJob — PRD §7, §7b, §13.3.
#
# Daily 04:00 UTC. Two responsibilities:
#   1. Auto-confirm any unconfirmed alias rows where confidence == 1.00
#      (exact tax_id matches), gated by AUTO_CONFIRM_EXACT_TAXID env (default true).
#   2. Emit `alias.pending_review` Hub event (template `vpi-alias-review`)
#      when remaining pending count > 20. Idempotent — silenced if same
#      tenant already emitted within 24h (state stamped on tenants.settings).
class Ingestion::AliasAutoConfirmJobTest < ActiveJob::TestCase
  setup do
    @acme   = tenants(:acme_gmbh_de)
    @globex = tenants(:globex_inc_us)
    @prev_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    @prev_auto = ENV["AUTO_CONFIRM_EXACT_TAXID"]
    ENV["AUTO_CONFIRM_EXACT_TAXID"] = "true"

    # Reset emit state on tenants
    [@acme, @globex].each do |t|
      t.update_columns(settings: (t.settings || {}).except("last_alias_review_emitted_at"))
    end
  end

  teardown do
    Current.tenant = nil
    ActiveJob::Base.queue_adapter = @prev_adapter
    ENV["AUTO_CONFIRM_EXACT_TAXID"] = @prev_auto
  end

  test "auto-confirms unconfirmed aliases with confidence 1.00" do
    vendor = vendors(:acme_alpha)
    a = VendorAlias.create!(
      tenant: @acme, vendor: vendor,
      source_system: "manual", source_ref: "TEST-AUTO-CONF-#{SecureRandom.hex(4)}",
      alias_text: "Alpha Test", confidence: 1.00, is_confirmed: false
    )

    Ingestion::AliasAutoConfirmJob.perform_now

    assert a.reload.is_confirmed, "expected exact-confidence alias to be auto-confirmed"
  end

  test "does not auto-confirm when AUTO_CONFIRM_EXACT_TAXID=false" do
    ENV["AUTO_CONFIRM_EXACT_TAXID"] = "false"
    vendor = vendors(:acme_alpha)
    a = VendorAlias.create!(
      tenant: @acme, vendor: vendor,
      source_system: "manual", source_ref: "TEST-NOAUTO-#{SecureRandom.hex(4)}",
      alias_text: "Alpha Test", confidence: 1.00, is_confirmed: false
    )

    Ingestion::AliasAutoConfirmJob.perform_now

    refute a.reload.is_confirmed, "expected alias to remain pending when env flag off"
  end

  test "leaves <1.00 confidence aliases untouched" do
    pending_alias = vendor_aliases(:acme_alpha_secondary)
    assert_equal 0.85.to_d, pending_alias.confidence
    refute pending_alias.is_confirmed

    Ingestion::AliasAutoConfirmJob.perform_now

    refute pending_alias.reload.is_confirmed, "0.85-confidence alias must stay pending"
  end

  test "emits Hub event when pending count > 20" do
    vendor = vendors(:acme_alpha)
    21.times do |i|
      VendorAlias.create!(
        tenant: @acme, vendor: vendor,
        source_system: "manual", source_ref: "PENDING-A-#{i}-#{SecureRandom.hex(2)}",
        alias_text: "Pending #{i}", confidence: 0.85, is_confirmed: false
      )
    end

    captured = []
    fake_hub = Object.new
    fake_hub.define_singleton_method(:enabled?) { true }
    fake_hub.define_singleton_method(:send_event) { |payload|
      captured << payload
      { status: :sent, hub_event_id: SecureRandom.uuid, response_code: 202 }
    }

    prev_hub = Ecosystem::HubClient.instance
    begin
      Ecosystem::HubClient.instance = fake_hub
      Ingestion::AliasAutoConfirmJob.perform_now
    ensure
      Ecosystem::HubClient.instance = prev_hub
    end

    assert_equal 1, captured.size, "expected one Hub event for acme"
    payload = captured.first
    assert_equal "vpi.alias.v1", payload[:schema_version]
    assert_equal "vpi-alias-review", payload[:template_id]
    assert payload[:pending_count] >= 21
    assert_equal @acme.id, payload[:tenant][:id]
  end

  test "does not emit Hub event when pending count <= 20" do
    captured = []
    fake_hub = Object.new
    fake_hub.define_singleton_method(:enabled?) { true }
    fake_hub.define_singleton_method(:send_event) { |payload| captured << payload; { status: :sent, hub_event_id: "x" } }

    prev_hub = Ecosystem::HubClient.instance
    begin
      Ecosystem::HubClient.instance = fake_hub
      Ingestion::AliasAutoConfirmJob.perform_now
    ensure
      Ecosystem::HubClient.instance = prev_hub
    end

    assert_equal 0, captured.size
  end

  test "honors 24h dedup window — recent emit silenced" do
    vendor = vendors(:acme_alpha)
    21.times do |i|
      VendorAlias.create!(
        tenant: @acme, vendor: vendor,
        source_system: "manual", source_ref: "DEDUP-#{i}-#{SecureRandom.hex(2)}",
        alias_text: "Pending #{i}", confidence: 0.85, is_confirmed: false
      )
    end
    @acme.update!(settings: (@acme.settings || {}).merge(
      "last_alias_review_emitted_at" => 1.hour.ago.utc.iso8601
    ))

    captured = []
    fake_hub = Object.new
    fake_hub.define_singleton_method(:enabled?) { true }
    fake_hub.define_singleton_method(:send_event) { |payload| captured << payload; { status: :sent, hub_event_id: "x" } }

    prev_hub = Ecosystem::HubClient.instance
    begin
      Ecosystem::HubClient.instance = fake_hub
      Ingestion::AliasAutoConfirmJob.perform_now
    ensure
      Ecosystem::HubClient.instance = prev_hub
    end

    assert_equal 0, captured.size, "expected dedup to silence emit"
  end

  test "Hub disabled: detection runs but no HTTP call" do
    vendor = vendors(:acme_alpha)
    21.times do |i|
      VendorAlias.create!(
        tenant: @acme, vendor: vendor,
        source_system: "manual", source_ref: "HUBOFF-#{i}-#{SecureRandom.hex(2)}",
        alias_text: "Pending #{i}", confidence: 0.85, is_confirmed: false
      )
    end

    captured = []
    fake_hub = Object.new
    fake_hub.define_singleton_method(:enabled?) { false }
    fake_hub.define_singleton_method(:send_event) { |payload| captured << payload; { status: :skipped } }

    prev_hub = Ecosystem::HubClient.instance
    begin
      Ecosystem::HubClient.instance = fake_hub
      Ingestion::AliasAutoConfirmJob.perform_now
    ensure
      Ecosystem::HubClient.instance = prev_hub
    end

    assert_equal 0, captured.size, "expected no Hub HTTP call when disabled"
    # State NOT stamped, so next run with Hub on can fire
    @acme.reload
    assert_nil (@acme.settings || {})["last_alias_review_emitted_at"]
  end
end
