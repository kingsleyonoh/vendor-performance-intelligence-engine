# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/vcr_setup"

# VCR cassette test for Ecosystem::ReconEngineClient — PRD §13.2 + §12 #12.
class ReconEngineClientCassetteTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  setup do
    @prev_enabled = ENV["RECON_ENGINE_ENABLED"]
    @prev_url     = ENV["RECON_ENGINE_URL"]
    @prev_key     = ENV["RECON_ENGINE_API_KEY"]
    ENV["RECON_ENGINE_ENABLED"] = "true"
    ENV["RECON_ENGINE_URL"]     = "http://recon-engine.example.test"
    ENV["RECON_ENGINE_API_KEY"] = "[FILTERED_API_KEY]"
  end

  teardown do
    ENV["RECON_ENGINE_ENABLED"] = @prev_enabled
    ENV["RECON_ENGINE_URL"]     = @prev_url
    ENV["RECON_ENGINE_API_KEY"] = @prev_key
  end

  test "list_discrepancies replays cassette → returns :ok + parses discrepancies" do
    client = Ecosystem::ReconEngineClient.new

    VCR.use_cassette("recon_engine_client/list_discrepancies") do
      result = client.list_discrepancies

      assert_equal :ok, result[:status]
      assert_equal 200, result[:response_code]
      assert_kind_of Array, result[:discrepancies]
      assert_equal 1, result[:discrepancies].size
      assert_equal "dx-1", result[:discrepancies].first["id"]
    end
  end
end
