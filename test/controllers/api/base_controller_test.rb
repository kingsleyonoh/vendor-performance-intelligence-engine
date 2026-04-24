# frozen_string_literal: true

require "test_helper"

# Integration-style test for Api::BaseController. Wires a scratch TestController
# to scratch routes so we can exercise the shared rescue_from handlers and the
# render_api_error helper without waiting for feature controllers.
module Api
  class BaseControllerTest < ActionDispatch::IntegrationTest
    # Scratch subclass of Api::BaseController. Each action deliberately provokes
    # one rescue_from path or exercises the render_api_error helper directly.
    class ScratchController < ::Api::BaseController
      skip_before_action :require_tenant!, except: [:needs_tenant]

      def ok
        if params[:explode] == "notfound"
          return render_api_error(::Errors::JsonApiError::NOT_FOUND, message: "forced")
        end

        render json: { ok: true }
      end

      def raises_record_not_found
        raise ActiveRecord::RecordNotFound, "no such row"
      end

      def raises_record_invalid
        record = ::FakeInvalidRecord.new
        record.errors.add(:legal_name, "can't be blank")
        raise ActiveRecord::RecordInvalid, record
      end

      def raises_not_unique
        raise ActiveRecord::RecordNotUnique, "duplicate key value"
      end

      def raises_action_policy_unauthorized
        # ActionPolicy::Unauthorized expects (policy_instance, rule, result).
        # Build a minimal stub that satisfies the constructor without needing
        # a real policy class wired up in Batch 003.
        policy_stub = Struct.new(:result).new(Struct.new(:reasons).new([]))
        raise ActionPolicy::Unauthorized.new(policy_stub, :show?)
      end

      def raises_unhandled
        raise "something blew up"
      end

      def needs_tenant
        render json: { tenant_id: Current.tenant&.id }
      end
    end

    # Minimal ActiveModel-compatible record so RecordInvalid has something to
    # inspect (it calls `.errors` and `.class.model_name`). No migration needed.
    class ::FakeInvalidRecord
      include ActiveModel::Model

      def self.model_name
        ActiveModel::Name.new(self, nil, "FakeInvalidRecord")
      end

      def errors
        @errors ||= ActiveModel::Errors.new(self)
      end
    end

    setup do
      Rails.application.routes.draw do
        scope "/api/scratch" do
          get "/ok", to: "api/base_controller_test/scratch#ok"
          get "/record_not_found", to: "api/base_controller_test/scratch#raises_record_not_found"
          get "/record_invalid", to: "api/base_controller_test/scratch#raises_record_invalid"
          get "/not_unique", to: "api/base_controller_test/scratch#raises_not_unique"
          get "/policy_denied", to: "api/base_controller_test/scratch#raises_action_policy_unauthorized"
          get "/unhandled", to: "api/base_controller_test/scratch#raises_unhandled"
          get "/needs_tenant", to: "api/base_controller_test/scratch#needs_tenant"
        end
      end
    end

    teardown do
      Rails.application.reload_routes!
      Current.tenant = nil
    end

    test "render_api_error emits the PRD §8b envelope with code + message + mapped status" do
      get "/api/scratch/ok", params: { explode: "notfound" }

      assert_equal 404, response.status
      body = JSON.parse(response.body)
      assert_equal "NOT_FOUND", body.dig("error", "code")
      assert_equal "forced", body.dig("error", "message")
      assert_match %r{application/json}, response.headers["Content-Type"]
    end

    test "ActiveRecord::RecordNotFound → 404 NOT_FOUND envelope" do
      get "/api/scratch/record_not_found"

      assert_equal 404, response.status
      body = JSON.parse(response.body)
      assert_equal "NOT_FOUND", body.dig("error", "code")
      assert body.dig("error", "message").present?, "message must be populated"
    end

    test "ActiveRecord::RecordInvalid → 400 VALIDATION_ERROR with details array" do
      get "/api/scratch/record_invalid"

      assert_equal 400, response.status
      body = JSON.parse(response.body)
      assert_equal "VALIDATION_ERROR", body.dig("error", "code")
      details = body.dig("error", "details")
      assert_kind_of Array, details
      assert details.any? { |d| d["path"] == "legal_name" }, "details must surface field-level errors"
    end

    test "ActiveRecord::RecordNotUnique → 409 CONFLICT envelope" do
      get "/api/scratch/not_unique"

      assert_equal 409, response.status
      body = JSON.parse(response.body)
      assert_equal "CONFLICT", body.dig("error", "code")
    end

    test "ActionPolicy::Unauthorized → 403 FORBIDDEN envelope" do
      get "/api/scratch/policy_denied"

      assert_equal 403, response.status
      body = JSON.parse(response.body)
      assert_equal "FORBIDDEN", body.dig("error", "code")
    end

    test "require_tenant! raises UNAUTHORIZED when Current.tenant is nil" do
      Current.tenant = nil
      get "/api/scratch/needs_tenant"

      assert_equal 401, response.status
      body = JSON.parse(response.body)
      assert_equal "UNAUTHORIZED", body.dig("error", "code")
    end

    test "unhandled StandardError → 500 INTERNAL_ERROR envelope with scrubbed message" do
      get "/api/scratch/unhandled"

      assert_equal 500, response.status
      body = JSON.parse(response.body)
      assert_equal "INTERNAL_ERROR", body.dig("error", "code")
      # Must NOT leak internal exception class / text.
      refute_match(/RuntimeError|something blew up/, body.dig("error", "message").to_s)
    end
  end
end
