# frozen_string_literal: true

require "test_helper"

module Errors
  class JsonApiErrorTest < ActiveSupport::TestCase
    test "exposes the 8 canonical error codes as string constants" do
      assert_equal "VALIDATION_ERROR", JsonApiError::VALIDATION_ERROR
      assert_equal "UNAUTHORIZED", JsonApiError::UNAUTHORIZED
      assert_equal "FORBIDDEN", JsonApiError::FORBIDDEN
      assert_equal "NOT_FOUND", JsonApiError::NOT_FOUND
      assert_equal "CONFLICT", JsonApiError::CONFLICT
      assert_equal "RATE_LIMITED", JsonApiError::RATE_LIMITED
      assert_equal "INTERNAL_ERROR", JsonApiError::INTERNAL_ERROR
      assert_equal "SERVICE_UNAVAILABLE", JsonApiError::SERVICE_UNAVAILABLE
    end

    test "ALL_CODES returns exactly the 8 canonical codes" do
      assert_equal 8, JsonApiError::ALL_CODES.size
      assert_includes JsonApiError::ALL_CODES, "VALIDATION_ERROR"
      assert_includes JsonApiError::ALL_CODES, "SERVICE_UNAVAILABLE"
    end

    test "http_status_for maps each code to its documented HTTP status (PRD §8b)" do
      assert_equal 400, JsonApiError.http_status_for("VALIDATION_ERROR")
      assert_equal 401, JsonApiError.http_status_for("UNAUTHORIZED")
      assert_equal 403, JsonApiError.http_status_for("FORBIDDEN")
      assert_equal 404, JsonApiError.http_status_for("NOT_FOUND")
      assert_equal 409, JsonApiError.http_status_for("CONFLICT")
      assert_equal 429, JsonApiError.http_status_for("RATE_LIMITED")
      assert_equal 500, JsonApiError.http_status_for("INTERNAL_ERROR")
      assert_equal 503, JsonApiError.http_status_for("SERVICE_UNAVAILABLE")
    end

    test "http_status_for accepts symbol codes equivalent to strings" do
      assert_equal 400, JsonApiError.http_status_for(:validation_error)
      assert_equal 404, JsonApiError.http_status_for(:not_found)
    end

    test "http_status_for raises ArgumentError for unknown code" do
      assert_raises(ArgumentError) { JsonApiError.http_status_for("TEAPOT") }
      assert_raises(ArgumentError) { JsonApiError.http_status_for(nil) }
      assert_raises(ArgumentError) { JsonApiError.http_status_for("") }
    end

    test "code constants are frozen strings" do
      assert JsonApiError::VALIDATION_ERROR.frozen?,
        "VALIDATION_ERROR must be frozen to prevent accidental mutation"
    end
  end
end
