# frozen_string_literal: true

require "test_helper"

# Template-lint CI gate (PRD §13.3, §15 #14 + #15). Enforces the strict-
# undefined contract on every ERB report template by rendering each
# template against representative `render_context` fixtures for TWO
# distinct tenants (Acme + Globex). Any token a template references but
# the captured render_context does NOT supply MUST raise
# `Reports::StrictFetchError` — silent fall-through to an empty string
# is exactly the bug class this gate exists to catch.
#
# This file is the regression gate for §15 criterion #14 ("CI fails when
# any report template references a token not present in the §5.6
# RenderContext shape") and #15 ("every report template renders cleanly
# under two distinct tenant fixtures").
class ReportTemplateLintTest < ActiveSupport::TestCase
  TEMPLATES = {
    "vendor_scorecard"     => Rails.root.join("app/views/reports/vendor_scorecard.pdf.erb"),
    "portfolio_risk"       => Rails.root.join("app/views/reports/portfolio_risk.pdf.erb"),
    "trend_analysis"       => Rails.root.join("app/views/reports/trend_analysis.pdf.erb")
    # `retender_candidates` has no PDF template (CSV-only) per Batch 024.
  }.freeze

  TENANT_FIXTURES = {
    acme:   :acme_gmbh_de,
    globex: :globex_inc_us
  }.freeze

  TEMPLATES.each do |report_type, template_path|
    TENANT_FIXTURES.each do |tenant_label, fixture_name|
      define_method "test_#{report_type}_renders_cleanly_for_#{tenant_label}_tenant" do
        ctx = capture_render_context_for(report_type, fixture_name)
        # Strict-undefined assertion: ANY missing token MUST raise. The
        # success path is "no exception."
        result = render_template(template_path, ctx)
        assert result.is_a?(String), "render must produce a String"
        assert result.bytesize > 100, "render must produce non-trivial HTML output"
      end

      define_method "test_#{report_type}_for_#{tenant_label}_does_not_leak_other_tenants_identity" do
        # Multi-tenant fixture coverage (§15 #15): rendering Tenant A
        # must NEVER include any Tenant B identity literal.
        ctx = capture_render_context_for(report_type, fixture_name)
        rendered = render_template(template_path, ctx)

        other_label = tenant_label == :acme ? :globex : :acme
        other = tenants(TENANT_FIXTURES[other_label])
        leak_terms = [
          other.legal_name,
          other.full_legal_name,
          other.contact["email"],
          other.address["line1"]
        ].compact.reject(&:empty?)

        leak_terms.each do |term|
          refute_includes rendered, term,
                          "TENANT_IDENTITY_LEAK: #{report_type} render for #{tenant_label} " \
                          "contains literal `#{term}` from #{other_label}"
        end
      end
    end
  end

  test "deliberately broken template raises StrictFetchError on missing token" do
    # Synthetic regression: a template that references an unmapped token
    # MUST raise `Reports::StrictFetchError`. If the strict-fetch gate
    # were ever weakened (default: nil silently), this test would pass
    # silently — that is exactly the failure mode this gate prevents.
    broken_template = <<~ERB
      <html><body>
        <p>Tenant: <%= h(f("tenant.legal_name")) %></p>
        <p>Bogus: <%= h(f("tenant.this_field_does_not_exist_anywhere")) %></p>
      </body></html>
    ERB

    ctx = capture_render_context_for("vendor_scorecard", :acme_gmbh_de)

    assert_raises(::Reports::StrictFetchError) do
      view = ::Reports::VendorScorecardGenerator::TemplateContext.new(
        stringify_keys_deep(ctx)
      )
      ERB.new(broken_template, trim_mode: "-").result(view.binding_for_template)
    end
  end

  test "every template references only paths that resolve in render_context" do
    # Static analysis pass: scan each template for `f(...)` calls and
    # verify each path resolves against the captured render_context
    # WITHOUT a default. Tokens with `default:` are tolerated as
    # legitimately optional (e.g. `data.vendor.category`).
    TEMPLATES.each do |report_type, template_path|
      ctx = stringify_keys_deep(capture_render_context_for(report_type, :acme_gmbh_de))
      mandatory_paths = extract_mandatory_paths(File.read(template_path))
      mandatory_paths.each do |path|
        # `assert_nothing_raised` rejects positional args; we wrap the
        # fetch in a begin/rescue so a StrictFetchError surfaces as a
        # failure with a useful message.
        ::Reports::StrictFetch.fetch_path(ctx, path)
        assert true, "path `#{path}` resolved for #{report_type}"
      rescue ::Reports::StrictFetchError => e
        flunk "Template `#{template_path.basename}` references mandatory token `#{path}` " \
              "that does NOT resolve in the captured render_context for #{report_type}: #{e.message}"
      end
    end
  end

  private

  # Build a real captured render_context for the given report_type and
  # tenant. We seed minimum data so each capturer has something to work
  # with — the captured shape is what the templates bind against.
  def capture_render_context_for(report_type, tenant_fixture_name)
    tenant = tenants(tenant_fixture_name)
    vendor = case tenant_fixture_name
             when :acme_gmbh_de   then vendors(:acme_alpha)
             when :globex_inc_us  then vendors(:globex_zeta)
             end

    report = VendorReport.create!(
      tenant: tenant,
      vendor: report_type == "vendor_scorecard" ? vendor : nil,
      report_type: report_type,
      output_format: report_type == "vendor_scorecard" ? "pdf" : "csv",
      parameters: report_type == "trend_analysis" ? { window_days: 90 } : {},
      status: "queued"
    )
    Reports::CaptureRenderContext.call(vendor_report: report)
  end

  # Mirror BaseGenerator#stringify_keys_deep so test assertions binding
  # to string-key paths work regardless of whether the captured context
  # was symbolized or stringified at storage time.
  def stringify_keys_deep(obj)
    case obj
    when Hash  then obj.each_with_object({}) { |(k, v), out| out[k.to_s] = stringify_keys_deep(v) }
    when Array then obj.map { |v| stringify_keys_deep(v) }
    else            obj
    end
  end

  def render_template(template_path, ctx)
    template_source = File.read(template_path)
    view = ::Reports::VendorScorecardGenerator::TemplateContext.new(
      stringify_keys_deep(ctx)
    )
    ERB.new(template_source, trim_mode: "-").result(view.binding_for_template)
  end

  # Scan an ERB template for `f("path")` and `f("path", default: …)` and
  # return ONLY the paths without a default — those are the mandatory
  # tokens the render_context MUST supply.
  def extract_mandatory_paths(source)
    # Match `f("path", default: …)` first and exclude — these are
    # legitimately optional (e.g. `data.vendor.category`, addresses).
    optional = source.scan(/f\(\s*"([^"]+)"\s*,\s*default:/).flatten.to_set
    mandatory = source.scan(/f\(\s*"([^"]+)"\s*\)/).flatten
    mandatory.uniq - optional.to_a
  end
end
