# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/vcr_setup"

# VCR cassette test for Ecosystem::WorkflowClient — PRD §13.2 + §12 #12.
class WorkflowClientCassetteTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  setup do
    @prev_enabled = ENV["WORKFLOW_ENGINE_ENABLED"]
    @prev_url     = ENV["WORKFLOW_ENGINE_URL"]
    @prev_key     = ENV["WORKFLOW_ENGINE_API_KEY"]
    ENV["WORKFLOW_ENGINE_ENABLED"] = "true"
    ENV["WORKFLOW_ENGINE_URL"]     = "http://workflow-engine.example.test"
    ENV["WORKFLOW_ENGINE_API_KEY"] = "[FILTERED_API_KEY]"
  end

  teardown do
    ENV["WORKFLOW_ENGINE_ENABLED"] = @prev_enabled
    ENV["WORKFLOW_ENGINE_URL"]     = @prev_url
    ENV["WORKFLOW_ENGINE_API_KEY"] = @prev_key
  end

  test "execute replays cassette → returns :executed + parses execution_id" do
    client = Ecosystem::WorkflowClient.new

    VCR.use_cassette("workflow_client/execute") do
      result = client.execute(
        workflow_id: "vpi-risk-escalation-default",
        payload: {
          alert_id: "alrt-789",
          tenant: { slug: "acme" },
          vendor: { id: "v-1" }
        }
      )

      assert_equal :executed, result[:status]
      assert_equal "wf-exec-cassette-001", result[:execution_id]
      assert_equal 202, result[:response_code]
    end
  end
end
