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

      def create
        render json: { created: true }, status: :created
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

    # Fixture key for the acme tenant — matches `test/fixtures/tenants.yml`.
    # Supplied as a default header so the ApiKeyAuthenticator middleware
    # (registered in Batch 007) passes every scratch-route request through
    # to the controller. Per-test Current.tenant manipulation still works
    # because the middleware-set value is overwritten in-test where needed.
    ACME_RAW_KEY = "vpi_test_acme_key_00000000000000000000"

    setup do
      @previous_cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new

      Rails.application.routes.draw do
        scope "/api/scratch" do
          get "/ok", to: "api/base_controller_test/scratch#ok"
          get "/record_not_found", to: "api/base_controller_test/scratch#raises_record_not_found"
          get "/record_invalid", to: "api/base_controller_test/scratch#raises_record_invalid"
          get "/not_unique", to: "api/base_controller_test/scratch#raises_not_unique"
          get "/policy_denied", to: "api/base_controller_test/scratch#raises_action_policy_unauthorized"
          get "/unhandled", to: "api/base_controller_test/scratch#raises_unhandled"
          get "/needs_tenant", to: "api/base_controller_test/scratch#needs_tenant"
          post "/create", to: "api/base_controller_test/scratch#create"
        end
      end
    end

    teardown do
      Rails.application.reload_routes!
      Current.tenant = nil
      Rails.cache = @previous_cache if @previous_cache
    end

    # Helper that rides the global test auth key so scratch routes get past
    # the middleware.
    def get_scratch(path, params: nil)
      get path, params: params, headers: { "X-API-Key" => ACME_RAW_KEY }
    end

    def post_scratch(path, params: nil)
      post path, params: params, headers: { "X-API-Key" => ACME_RAW_KEY }
    end

    test "render_api_error emits the PRD §8b envelope with code + message + mapped status" do
      get_scratch "/api/scratch/ok", params: { explode: "notfound" }

      assert_equal 404, response.status
      body = JSON.parse(response.body)
      assert_equal "NOT_FOUND", body.dig("error", "code")
      assert_equal "forced", body.dig("error", "message")
      assert_match %r{application/json}, response.headers["Content-Type"]
    end

    test "ActiveRecord::RecordNotFound → 404 NOT_FOUND envelope" do
      get_scratch "/api/scratch/record_not_found"

      assert_equal 404, response.status
      body = JSON.parse(response.body)
      assert_equal "NOT_FOUND", body.dig("error", "code")
      assert body.dig("error", "message").present?, "message must be populated"
    end

    test "ActiveRecord::RecordInvalid → 400 VALIDATION_ERROR with details array" do
      get_scratch "/api/scratch/record_invalid"

      assert_equal 400, response.status
      body = JSON.parse(response.body)
      assert_equal "VALIDATION_ERROR", body.dig("error", "code")
      details = body.dig("error", "details")
      assert_kind_of Array, details
      assert details.any? { |d| d["path"] == "legal_name" }, "details must surface field-level errors"
    end

    test "ActiveRecord::RecordNotUnique → 409 CONFLICT envelope" do
      get_scratch "/api/scratch/not_unique"

      assert_equal 409, response.status
      body = JSON.parse(response.body)
      assert_equal "CONFLICT", body.dig("error", "code")
    end

    test "ActionPolicy::Unauthorized → 403 FORBIDDEN envelope" do
      get_scratch "/api/scratch/policy_denied"

      assert_equal 403, response.status
      body = JSON.parse(response.body)
      assert_equal "FORBIDDEN", body.dig("error", "code")
    end

    test "require_tenant! raises UNAUTHORIZED when Current.tenant is nil" do
      # Deliberately do NOT pass X-API-Key — middleware stops the request at 401
      # with the same envelope the controller would emit via require_tenant!.
      Current.tenant = nil
      get "/api/scratch/needs_tenant"

      assert_equal 401, response.status
      body = JSON.parse(response.body)
      assert_equal "UNAUTHORIZED", body.dig("error", "code")
    end

    test "audit hook fires on successful mutating actions (POST) via Audit::Recorder" do
      # Capture Rails.logger into a StringIO so we can observe the
      # [audit]-tagged line that Audit::Recorder emits in Batch 005 (pre-
      # Phase-3 audit_log migration).
      log_io = StringIO.new
      logger = Logger.new(log_io)
      logger.formatter = ->(_severity, _time, _progname, msg) { "#{msg}\n" }
      previous_logger = Rails.logger
      Rails.logger = ActiveSupport::TaggedLogging.new(logger)
      Current.tenant = Struct.new(:id).new("audit-tenant-1")

      begin
        post_scratch "/api/scratch/create"
        assert_equal 201, response.status
        assert_match(/\[audit\]/, log_io.string,
                     "expected an [audit]-tagged line after a successful POST mutating action")
      ensure
        Rails.logger = previous_logger
        Current.tenant = nil
      end
    end

    test "audit hook does NOT fire on non-mutating actions (GET)" do
      log_io = StringIO.new
      logger = Logger.new(log_io)
      logger.formatter = ->(_severity, _time, _progname, msg) { "#{msg}\n" }
      previous_logger = Rails.logger
      Rails.logger = ActiveSupport::TaggedLogging.new(logger)

      begin
        get_scratch "/api/scratch/ok"
        assert_equal 200, response.status
        refute_match(/\[audit\]/, log_io.string,
                     "GET actions must not trigger audit recording")
      ensure
        Rails.logger = previous_logger
      end
    end

    test "unhandled StandardError → 500 INTERNAL_ERROR envelope with scrubbed message" do
      get_scratch "/api/scratch/unhandled"

      assert_equal 500, response.status
      body = JSON.parse(response.body)
      assert_equal "INTERNAL_ERROR", body.dig("error", "code")
      # Must NOT leak internal exception class / text.
      refute_match(/RuntimeError|something blew up/, body.dig("error", "message").to_s)
    end
  end
end
