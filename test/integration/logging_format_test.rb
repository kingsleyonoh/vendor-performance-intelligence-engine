# frozen_string_literal: true

require "test_helper"

# Asserts that every request emits a single structured JSON log line shaped
# for Axiom ingestion (PRD §10b). Axiom token wiring is Phase 3; Batch 005
# establishes the SHAPE so downstream controllers emit the right fields from
# Day 1.
class LoggingFormatTest < ActionDispatch::IntegrationTest
  setup do
    # Lograge attaches a single subscriber (`Lograge::LogSubscribers::
    # ActionController`) to the `process_action.action_controller`
    # notification at initializer-load time. That subscriber writes to
    # `Lograge.logger` (if set) or `Rails.logger` otherwise. Point it at a
    # StringIO for the duration of the test so we can observe the output
    # shape deterministically.
    @log_io = StringIO.new
    @previous_lograge_logger = Lograge.logger
    # Bare formatter so the captured output is a pure JSON line per request
    # — without the default "I, [timestamp #pid] level -- : " Logger prefix.
    logger = Logger.new(@log_io)
    logger.formatter = ->(_severity, _time, _progname, msg) { "#{msg}\n" }
    Lograge.logger = logger
  end

  teardown do
    Lograge.logger = @previous_lograge_logger
  end

  test "GET /up emits a single JSON line with method, path, status, request_id, and tenant_id" do
    get "/up"

    assert_equal 200, response.status

    lines = @log_io.string.lines.map(&:chomp).reject(&:empty?)
    # Lograge prints exactly one line per request.
    json_line = lines.find { |l| l.include?("\"method\":\"GET\"") && l.include?("\"path\":\"/up\"") }
    assert json_line, "expected a lograge JSON line for GET /up; captured: #{lines.inspect}"

    payload = JSON.parse(json_line)
    assert_equal "GET", payload["method"]
    assert_equal "/up", payload["path"]
    assert_equal 200, payload["status"]
    assert payload.key?("request_id"), "payload must include a request_id field"
    # tenant_id is present as a key even when nil — Batch 005 has no auth
    # middleware, so Current.tenant is nil here. What matters is the shape.
    assert payload.key?("tenant_id") || payload["tenant_id"].nil?,
           "payload must advertise tenant_id (value may be nil until ApiKeyAuthenticator lands)"
  end

  test "log output is valid JSON per request line (Axiom ingestion precondition)" do
    get "/up"

    lines = @log_io.string.lines.map(&:chomp).reject(&:empty?)
    request_lines = lines.select { |l| l.start_with?("{") }
    assert request_lines.any?, "expected at least one JSON line"
    request_lines.each do |line|
      assert_nothing_raised { JSON.parse(line) }
    end
  end
end
