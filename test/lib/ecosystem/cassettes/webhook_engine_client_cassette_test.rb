# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/vcr_setup"

# VCR cassette test for Ecosystem::WebhookEngineClient — PRD §13.2 + §12 #12.
class WebhookEngineClientCassetteTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  setup do
    @prev_enabled = ENV["WEBHOOK_ENGINE_ENABLED"]
    @prev_url     = ENV["WEBHOOK_ENGINE_URL"]
    @prev_key     = ENV["WEBHOOK_ENGINE_API_KEY"]
    ENV["WEBHOOK_ENGINE_ENABLED"] = "true"
    ENV["WEBHOOK_ENGINE_URL"]     = "http://webhook-engine.example.test"
    ENV["WEBHOOK_ENGINE_API_KEY"] = "[FILTERED_API_KEY]"
  end

  teardown do
    ENV["WEBHOOK_ENGINE_ENABLED"] = @prev_enabled
    ENV["WEBHOOK_ENGINE_URL"]     = @prev_url
    ENV["WEBHOOK_ENGINE_API_KEY"] = @prev_key
  end

  test "list_sources replays cassette → returns :ok + parses sources array" do
    client = Ecosystem::WebhookEngineClient.new

    VCR.use_cassette("webhook_engine_client/list_sources") do
      result = client.list_sources

      assert_equal :ok, result[:status]
      assert_equal 200, result[:response_code]
      assert_kind_of Array, result[:sources]
      assert_equal 2, result[:sources].size
      assert_equal "src-1", result[:sources].first["id"]
    end
  end
end
