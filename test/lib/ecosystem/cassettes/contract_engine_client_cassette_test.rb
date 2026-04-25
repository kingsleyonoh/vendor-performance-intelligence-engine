# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/vcr_setup"

# VCR cassette test for Ecosystem::ContractEngineClient — PRD §13.2 + §12 #12.
class ContractEngineClientCassetteTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  setup do
    @prev_enabled = ENV["CONTRACT_ENGINE_ENABLED"]
    @prev_url     = ENV["CONTRACT_ENGINE_URL"]
    @prev_key     = ENV["CONTRACT_ENGINE_API_KEY"]
    ENV["CONTRACT_ENGINE_ENABLED"] = "true"
    ENV["CONTRACT_ENGINE_URL"]     = "http://contract-engine.example.test"
    ENV["CONTRACT_ENGINE_API_KEY"] = "[FILTERED_API_KEY]"
  end

  teardown do
    ENV["CONTRACT_ENGINE_ENABLED"] = @prev_enabled
    ENV["CONTRACT_ENGINE_URL"]     = @prev_url
    ENV["CONTRACT_ENGINE_API_KEY"] = @prev_key
  end

  test "list_obligations replays cassette → returns :ok + parses obligations" do
    client = Ecosystem::ContractEngineClient.new

    VCR.use_cassette("contract_engine_client/list_obligations") do
      result = client.list_obligations(vendor_ref: "v-acme-1")

      assert_equal :ok, result[:status]
      assert_equal 200, result[:response_code]
      assert_kind_of Array, result[:obligations]
      assert_equal 2, result[:obligations].size
      assert_equal "ob-1", result[:obligations].first["id"]
    end
  end
end
