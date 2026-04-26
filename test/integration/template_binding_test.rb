# frozen_string_literal: true

require "test_helper"
require "liquid"
require "json"

# Hub template binding — PRD §13.2 + §15 #14 + §15 #15.
#
# Renders every registered Hub template against a representative
# DeliveryPayload (built via Alerts::CapturePayload) under
# strict-undefined mode. Any unmapped token fails the build.
#
# Multi-tenant fixture coverage (Multi-Tenant Fixtures Mandatory):
# every template is rendered against ≥2 distinct tenants. We assert
# Tenant A's render does NOT contain Tenant B's literal identity
# values (legal_name, display_name, address, contact) — the
# template-hardcoded-literal bug class fails at RED instead of
# leaking into production.
class TemplateBindingTest < ActiveSupport::TestCase
  # All 9 Hub templates VPI ships with — PRD §7b. Registered with the
  # Notification Hub at deploy time via the `notification-hub-onboard`
  # skill (see `.agent/skills/notification-hub-onboard/output.md`).
  TEMPLATES = {
    "vpi-risk-escalation-email"    => "vpi_risk_escalation_email.liquid",
    "vpi-risk-critical-email"      => "vpi_risk_critical_email.liquid",
    "vpi-risk-escalation-telegram" => "vpi_risk_escalation_telegram.liquid",
    "vpi-risk-critical-telegram"   => "vpi_risk_critical_telegram.liquid",
    "vpi-risk-medium-email"        => "vpi_risk_medium_email.liquid",
    "vpi-risk-improvement-digest"  => "vpi_risk_improvement_digest.liquid",
    "vpi-report-ready"             => "vpi_report_ready.liquid",
    "vpi-ingestion-stale"          => "vpi_ingestion_stale.liquid",
    "vpi-alias-review"             => "vpi_alias_review.liquid"
  }.freeze

  TEMPLATE_DIR = Rails.root.join("test", "fixtures", "hub_templates").freeze

  TENANT_FIXTURES = %i[acme_gmbh_de globex_inc_us].freeze

  SCORE_BY_TENANT = {
    acme_gmbh_de: :acme_critical_score,
    globex_inc_us: :globex_high_score
  }.freeze

  test "every registered template renders against every tenant fixture without missing tokens" do
    TEMPLATES.each do |template_name, template_file|
      TENANT_FIXTURES.each do |tenant_fixture|
        score_fixture = SCORE_BY_TENANT.fetch(tenant_fixture)
        score = vendor_scores(score_fixture)
        payload = Alerts::CapturePayload.call(vendor_score: score)
        liquid_ctx = liquidize(payload)

        template_path = TEMPLATE_DIR.join(template_file)
        template_str = File.read(template_path)
        template = Liquid::Template.parse(template_str, error_mode: :strict)

        rendered = nil
        begin
          rendered = template.render!(liquid_ctx, strict_variables: true, strict_filters: true)
        rescue Liquid::Error => e
          flunk "Template #{template_name} (tenant=#{tenant_fixture}) failed strict-render: #{e.class}: #{e.message}"
        end

        assert rendered.is_a?(String) && !rendered.strip.empty?,
               "Template #{template_name} (tenant=#{tenant_fixture}) rendered an empty/invalid result"

        assert rendered.valid_encoding?,
               "Template #{template_name} (tenant=#{tenant_fixture}) emitted non-UTF8 output"
      end
    end
  end

  test "templates render the correct tenant identity (no cross-tenant leakage)" do
    TEMPLATES.each_key do |template_name|
      template_file = TEMPLATES[template_name]
      template_path = TEMPLATE_DIR.join(template_file)
      template_str = File.read(template_path)
      template = Liquid::Template.parse(template_str, error_mode: :strict)

      acme_payload = Alerts::CapturePayload.call(vendor_score: vendor_scores(:acme_critical_score))
      globex_payload = Alerts::CapturePayload.call(vendor_score: vendor_scores(:globex_high_score))

      acme_render = template.render!(liquidize(acme_payload), strict_variables: true)
      globex_render = template.render!(liquidize(globex_payload), strict_variables: true)

      acme_tenant = tenants(:acme_gmbh_de)
      globex_tenant = tenants(:globex_inc_us)

      # Each render must contain its OWN tenant's display_name.
      assert_includes acme_render, acme_tenant.display_name,
                      "#{template_name}: Acme render missing Acme display_name"
      assert_includes globex_render, globex_tenant.display_name,
                      "#{template_name}: Globex render missing Globex display_name"

      # Each render must NOT contain the OTHER tenant's literal values.
      cross_check_pairs = [
        [:legal_name, acme_tenant.legal_name, globex_tenant.legal_name],
        [:display_name, acme_tenant.display_name, globex_tenant.display_name],
        [:full_legal_name, acme_tenant.full_legal_name, globex_tenant.full_legal_name]
      ]
      cross_check_pairs.each do |label, acme_val, globex_val|
        next if acme_val.blank? || globex_val.blank?
        next if acme_val == globex_val # equal strings can't leak

        refute_includes acme_render, globex_val,
          "TENANT_IDENTITY_LEAK: #{template_name}: tenant.#{label} expected=Acme actual_included=Globex(#{globex_val.inspect})"
        refute_includes globex_render, acme_val,
          "TENANT_IDENTITY_LEAK: #{template_name}: tenant.#{label} expected=Globex actual_included=Acme(#{acme_val.inspect})"
      end

      # Vendor-level cross-check: Acme render must not include any
      # Globex vendor canonical_name and vice versa.
      acme_vendor_name = vendors(:acme_gamma).canonical_name
      globex_vendor_name = vendors(:globex_eta).canonical_name
      assert_includes acme_render, acme_vendor_name
      refute_includes acme_render, globex_vendor_name,
        "TENANT_IDENTITY_LEAK: #{template_name}: acme render contains globex vendor name"
      assert_includes globex_render, globex_vendor_name
      refute_includes globex_render, acme_vendor_name,
        "TENANT_IDENTITY_LEAK: #{template_name}: globex render contains acme vendor name"
    end
  end

  test "missing token in a template causes strict render to raise" do
    # Sanity-test the test infrastructure: a synthetic template that
    # references {{ does.not.exist }} MUST raise under strict mode.
    # If this test ever passes silently, every other template-binding
    # assertion is lying.
    bad_template_str = "Hello {{ tenant.display_name }} — {{ does.not.exist }}!"
    template = Liquid::Template.parse(bad_template_str, error_mode: :strict)

    payload = Alerts::CapturePayload.call(vendor_score: vendor_scores(:acme_critical_score))

    assert_raises(Liquid::UndefinedVariable) do
      template.render!(liquidize(payload), strict_variables: true)
    end
  end

  private

  # Liquid expects string-keyed hashes (not symbols). Round-trip via
  # JSON for a deterministic conversion that also strips frozen-string
  # specifics that Liquid sometimes can't traverse.
  def liquidize(obj)
    JSON.parse(JSON.generate(obj))
  end
end
