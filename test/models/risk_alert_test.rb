# frozen_string_literal: true

require "test_helper"

# RiskAlert — PRD §4.8. Status machine, idempotency, delivery_payload
# constraints, tenant isolation.
class RiskAlertTest < ActiveSupport::TestCase
  def base_attrs(tenant:, vendor:, score:)
    {
      tenant: tenant,
      vendor: vendor,
      previous_band: "low",
      new_band: "high",
      previous_score: 20.0,
      new_score: 65.0,
      direction: "escalation",
      triggered_by_score: score.id,
      status: "pending",
      delivery_payload: { alert_id: "x", vendor: { name: vendor.canonical_name } }
    }
  end

  test "creates a valid pending alert" do
    score = vendor_scores(:acme_alpha_current)
    alert = RiskAlert.new(base_attrs(tenant: tenants(:acme_gmbh_de), vendor: vendors(:acme_alpha), score: score))
    assert alert.valid?, alert.errors.full_messages.inspect
    assert alert.save
  end

  test "rejects unknown status (DB enum + Rails validator)" do
    score = vendor_scores(:acme_alpha_current)
    alert = RiskAlert.new(base_attrs(tenant: tenants(:acme_gmbh_de), vendor: vendors(:acme_alpha), score: score).merge(status: "bogus"))
    assert_not alert.valid?
    assert alert.errors[:status].any?
  end

  test "rejects unknown band on previous_band/new_band" do
    score = vendor_scores(:acme_alpha_current)
    base = base_attrs(tenant: tenants(:acme_gmbh_de), vendor: vendors(:acme_alpha), score: score)
    bad_prev = RiskAlert.new(base.merge(previous_band: "purple"))
    bad_new = RiskAlert.new(base.merge(new_band: "purple"))
    assert_not bad_prev.valid?
    assert_not bad_new.valid?
  end

  test "rejects unknown direction" do
    score = vendor_scores(:acme_alpha_current)
    bad = RiskAlert.new(base_attrs(tenant: tenants(:acme_gmbh_de), vendor: vendors(:acme_alpha), score: score).merge(direction: "sideways"))
    assert_not bad.valid?
    assert bad.errors[:direction].any?
  end

  test "delivery_payload required and must be a Hash" do
    score = vendor_scores(:acme_alpha_current)
    base = base_attrs(tenant: tenants(:acme_gmbh_de), vendor: vendors(:acme_alpha), score: score)

    no_payload = RiskAlert.new(base.merge(delivery_payload: nil))
    assert_not no_payload.valid?

    not_hash = RiskAlert.new(base.merge(delivery_payload: "string"))
    assert_not not_hash.valid?
    assert not_hash.errors[:delivery_payload].any?
  end

  test "tenant isolation — Acme alerts not visible to Globex queries" do
    score = vendor_scores(:acme_alpha_current)
    RiskAlert.create!(base_attrs(tenant: tenants(:acme_gmbh_de), vendor: vendors(:acme_alpha), score: score))

    acme_count = RiskAlert.where(tenant_id: tenants(:acme_gmbh_de).id).count
    globex_count = RiskAlert.where(tenant_id: tenants(:globex_inc_us).id).count

    assert_equal 1, acme_count
    assert_equal 0, globex_count
  end

  test "idempotency — duplicate (tenant, vendor, triggered_by_score) raises RecordNotUnique" do
    score = vendor_scores(:acme_alpha_current)
    attrs = base_attrs(tenant: tenants(:acme_gmbh_de), vendor: vendors(:acme_alpha), score: score)
    RiskAlert.create!(attrs)

    assert_raises(ActiveRecord::RecordNotUnique) do
      RiskAlert.create!(attrs)
    end
  end

  # ---- Status transitions ----

  test "transition: pending → dispatching is allowed" do
    alert = create_alert(status: "pending")
    alert.transition_to!("dispatching")
    assert_equal "dispatching", alert.reload.status
  end

  test "transition: pending → suppressed is allowed" do
    alert = create_alert(status: "pending")
    alert.transition_to!("suppressed")
    assert_equal "suppressed", alert.reload.status
  end

  test "transition: dispatching → delivered is allowed" do
    alert = create_alert(status: "dispatching")
    alert.transition_to!("delivered")
    assert_equal "delivered", alert.reload.status
  end

  test "transition: dispatching → failed is allowed" do
    alert = create_alert(status: "dispatching")
    alert.transition_to!("failed")
    assert_equal "failed", alert.reload.status
  end

  test "transition: failed → pending is allowed (retry path; failed is NOT terminal)" do
    alert = create_alert(status: "failed")
    alert.transition_to!("pending")
    assert_equal "pending", alert.reload.status
  end

  test "transition: pending → delivered is REJECTED (must go through dispatching)" do
    alert = create_alert(status: "pending")
    assert_raises(RiskAlert::InvalidStatusTransition) do
      alert.transition_to!("delivered")
    end
  end

  test "transition: delivered → pending is REJECTED" do
    alert = create_alert(status: "delivered")
    assert_raises(RiskAlert::InvalidStatusTransition) do
      alert.transition_to!("pending")
    end
  end

  test "transition: resolved is terminal — no transitions out" do
    alert = create_alert(status: "delivered")
    alert.transition_to!("acknowledged") { |a| a.acknowledged_at = Time.current; a.acknowledged_by = "ops@example" }
    alert.transition_to!("resolved")
    assert_raises(RiskAlert::InvalidStatusTransition) do
      alert.transition_to!("pending")
    end
  end

  test "transition: suppressed is terminal" do
    alert = create_alert(status: "suppressed")
    assert_raises(RiskAlert::InvalidStatusTransition) do
      alert.transition_to!("pending")
    end
  end

  test "acknowledge! sets acknowledged_at + acknowledged_by atomically" do
    alert = create_alert(status: "delivered")
    alert.acknowledge!(by: "ops@example.com")
    alert.reload
    assert_equal "acknowledged", alert.status
    assert_not_nil alert.acknowledged_at
    assert_equal "ops@example.com", alert.acknowledged_by
  end

  test "acknowledge! cannot be called twice" do
    alert = create_alert(status: "delivered")
    alert.acknowledge!(by: "ops@example.com")
    assert_raises(RiskAlert::InvalidStatusTransition) do
      alert.acknowledge!(by: "someone-else@example.com")
    end
  end

  private

  def create_alert(status:)
    score = vendor_scores(:acme_alpha_current)
    attrs = {
      tenant: tenants(:acme_gmbh_de),
      vendor: vendors(:acme_alpha),
      previous_band: "low",
      new_band: "high",
      previous_score: 20.0,
      new_score: 65.0,
      direction: "escalation",
      triggered_by_score: score.id,
      status: status,
      delivery_payload: { alert_id: "x" }
    }
    # For non-pending starting states, bypass the transition rules by
    # writing directly to the column on a freshly-built record.
    alert = RiskAlert.new(attrs)
    # Use insert_all so we don't have to walk through transitions to
    # reach the test's start state, and so the FK column matches.
    if status == "pending"
      alert.save!
      alert
    else
      alert.save!(validate: true)
      RiskAlert.where(id: alert.id).update_all(status: status)
      alert.reload
    end
  end
end
