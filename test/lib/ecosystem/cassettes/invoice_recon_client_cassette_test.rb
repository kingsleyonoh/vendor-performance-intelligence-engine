# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/vcr_setup"

# VCR cassette test for Ecosystem::InvoiceReconClient — PRD §13.2 + §12 #12.
class InvoiceReconClientCassetteTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  setup do
    @prev_enabled = ENV["INVOICE_RECON_ENABLED"]
    @prev_url     = ENV["INVOICE_RECON_URL"]
    @prev_key     = ENV["INVOICE_RECON_API_KEY"]
    ENV["INVOICE_RECON_ENABLED"] = "true"
    ENV["INVOICE_RECON_URL"]     = "http://invoice-recon.example.test"
    ENV["INVOICE_RECON_API_KEY"] = "[FILTERED_API_KEY]"
  end

  teardown do
    ENV["INVOICE_RECON_ENABLED"] = @prev_enabled
    ENV["INVOICE_RECON_URL"]     = @prev_url
    ENV["INVOICE_RECON_API_KEY"] = @prev_key
  end

  test "list_late_invoices replays cassette → returns :ok + parses invoices array" do
    client = Ecosystem::InvoiceReconClient.new

    VCR.use_cassette("invoice_recon_client/list_late_invoices") do
      result = client.list_late_invoices

      assert_equal :ok, result[:status]
      assert_equal 200, result[:response_code]
      assert_kind_of Array, result[:invoices]
      assert_equal 2, result[:invoices].size
      assert_equal "inv-1", result[:invoices].first["id"]
      assert_equal 1, result[:page]
      assert_equal 2, result[:total]
    end
  end
end
