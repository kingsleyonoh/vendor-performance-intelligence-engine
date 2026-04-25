# frozen_string_literal: true

require "test_helper"

# Pre-touch the StrictFetch module so Zeitwerk runs the file-level
# `Reports::StrictFetchError` alias assignment before any test references
# the alias.
Reports::StrictFetch

# Reports::StrictFetch — ERB equivalent of Liquid `strict_variables`.
# Looks up dot-paths against a render_context Hash and RAISES on any
# missing path. Backs every report ERB template — keeps templates honest
# the same way `strict: true` keeps Hub Liquid templates honest.
module Reports
  class StrictFetchTest < ActiveSupport::TestCase
    setup do
      @ctx = {
        schema_version: "vpi.report.v1",
        tenant: {
          id: "tenant-uuid-1",
          legal_name: "Acme GmbH",
          contact: {
            email: "ops@acme.example",
            phone: "+49 30 1234567"
          }
        },
        data: {
          vendor: {
            id: "vendor-uuid-1",
            canonical_name: "Alpha Maschinenbau AG"
          },
          score_history: [
            { composite_score: 15.5, band: "low" },
            { composite_score: 22.0, band: "medium" }
          ]
        }
      }
    end

    # ---------- Happy path ----------
    test "returns the value at a single-segment path" do
      assert_equal "vpi.report.v1", Reports::StrictFetch.fetch_path(@ctx, "schema_version")
    end

    test "returns the value at a nested dot path" do
      assert_equal "Acme GmbH", Reports::StrictFetch.fetch_path(@ctx, "tenant.legal_name")
    end

    test "returns the value at a deeply nested path" do
      assert_equal "ops@acme.example", Reports::StrictFetch.fetch_path(@ctx, "tenant.contact.email")
    end

    test "supports symbol and string keys interchangeably" do
      sym_ctx  = { tenant: { legal_name: "Acme" } }
      str_ctx  = { "tenant" => { "legal_name" => "Acme" } }
      mix_ctx  = { tenant: { "legal_name" => "Acme" } }

      assert_equal "Acme", Reports::StrictFetch.fetch_path(sym_ctx, "tenant.legal_name")
      assert_equal "Acme", Reports::StrictFetch.fetch_path(str_ctx, "tenant.legal_name")
      assert_equal "Acme", Reports::StrictFetch.fetch_path(mix_ctx, "tenant.legal_name")
    end

    # ---------- Array index paths ----------
    test "supports bracket array index syntax" do
      assert_equal 15.5, Reports::StrictFetch.fetch_path(@ctx, "data.score_history[0].composite_score")
      assert_equal "medium", Reports::StrictFetch.fetch_path(@ctx, "data.score_history[1].band")
    end

    test "raises on out-of-bounds array index" do
      assert_raises(Reports::StrictFetchError) do
        Reports::StrictFetch.fetch_path(@ctx, "data.score_history[99].band")
      end
    end

    # ---------- Missing paths raise ----------
    test "raises StrictFetchError on missing top-level key" do
      err = assert_raises(Reports::StrictFetchError) do
        Reports::StrictFetch.fetch_path(@ctx, "nonexistent")
      end
      assert_match(/nonexistent/, err.message)
    end

    test "raises StrictFetchError on missing nested key" do
      err = assert_raises(Reports::StrictFetchError) do
        Reports::StrictFetch.fetch_path(@ctx, "tenant.nonexistent_field")
      end
      assert_match(/nonexistent_field/, err.message)
    end

    test "raises StrictFetchError when traversing through nil" do
      assert_raises(Reports::StrictFetchError) do
        Reports::StrictFetch.fetch_path(@ctx, "tenant.address.line1")
      end
    end

    # ---------- Default kwarg ----------
    test "default kwarg returns default on missing path" do
      result = Reports::StrictFetch.fetch_path(@ctx, "tenant.contact.fax", default: "—")
      assert_equal "—", result
    end

    test "default kwarg does NOT mask present nil values; raises" do
      ctx = { tenant: { fax: nil } }
      # nil is a present key with nil value — strict semantics: raises if path
      # not allowed to be nil. We allow nil only via default kwarg.
      assert_raises(Reports::StrictFetchError) do
        Reports::StrictFetch.fetch_path(ctx, "tenant.fax")
      end

      assert_equal "—",
                   Reports::StrictFetch.fetch_path(ctx, "tenant.fax", default: "—")
    end

    # ---------- Empty path / argument errors ----------
    test "raises on empty path" do
      assert_raises(ArgumentError) { Reports::StrictFetch.fetch_path(@ctx, "") }
    end

    test "raises on nil context" do
      assert_raises(ArgumentError) { Reports::StrictFetch.fetch_path(nil, "tenant") }
    end
  end
end
