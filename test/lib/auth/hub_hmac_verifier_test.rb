# frozen_string_literal: true

require "test_helper"
require "openssl"

# Auth::HubHmacVerifier — PRD §13.2.
#
# Verifies HMAC-SHA256 signatures on inbound `/api/signals/from-hub`
# requests using the shared `HUB_INGRESS_SECRET`. Replay protection: a
# 5-minute timestamp window. Constant-time comparison via
# `ActiveSupport::SecurityUtils.secure_compare`.
class HubHmacVerifierTest < ActiveSupport::TestCase
  SECRET = "test-hub-ingress-secret-32bytes!"

  def with_secret
    prev = ENV["HUB_INGRESS_SECRET"]
    ENV["HUB_INGRESS_SECRET"] = SECRET
    yield
  ensure
    ENV["HUB_INGRESS_SECRET"] = prev
  end

  # Build a fake Rack-like request object that exposes the two surfaces
  # the verifier needs: header lookup + raw body.
  class FakeRequest
    def initialize(headers: {}, body: "")
      @headers = headers
      @body = body
    end

    # Mimic Rack: HTTP_X_VPI_SIGNATURE header is what Rails maps the
    # `X-VPI-Signature` header to. The verifier should accept either
    # path (Rails request.headers or raw env hash).
    def headers
      @headers
    end

    def raw_post
      @body
    end
  end

  def signed_request(body:, timestamp: Time.now.to_i, secret: SECRET)
    payload = "#{timestamp}.#{body}"
    sig_hex = OpenSSL::HMAC.hexdigest("SHA256", secret, payload)
    FakeRequest.new(
      headers: { "X-VPI-Signature" => "t=#{timestamp},v1=#{sig_hex}" },
      body: body
    )
  end

  test "valid signature + recent timestamp → verify returns true" do
    with_secret do
      req = signed_request(body: '{"hello":"world"}')
      assert Auth::HubHmacVerifier.verify(req)
    end
  end

  test "tampered body → verify returns false" do
    with_secret do
      req = signed_request(body: '{"hello":"world"}')
      # Mutate the body after signing.
      tampered = FakeRequest.new(headers: req.headers, body: '{"hello":"WORLD"}')
      refute Auth::HubHmacVerifier.verify(tampered)
    end
  end

  test "stale timestamp (>5 min) → verify returns false" do
    with_secret do
      stale_ts = Time.now.to_i - 600 # 10 minutes ago
      req = signed_request(body: "{}", timestamp: stale_ts)
      refute Auth::HubHmacVerifier.verify(req)
    end
  end

  test "future timestamp (>5 min ahead) → verify returns false" do
    with_secret do
      future_ts = Time.now.to_i + 600
      req = signed_request(body: "{}", timestamp: future_ts)
      refute Auth::HubHmacVerifier.verify(req)
    end
  end

  test "missing X-VPI-Signature header → verify returns false" do
    with_secret do
      req = FakeRequest.new(headers: {}, body: "{}")
      refute Auth::HubHmacVerifier.verify(req)
    end
  end

  test "malformed header (no v1) → verify returns false" do
    with_secret do
      req = FakeRequest.new(
        headers: { "X-VPI-Signature" => "t=#{Time.now.to_i},garbage" },
        body: "{}"
      )
      refute Auth::HubHmacVerifier.verify(req)
    end
  end

  test "wrong secret → verify returns false" do
    with_secret do
      req = signed_request(body: "{}", secret: "wrong-secret")
      refute Auth::HubHmacVerifier.verify(req)
    end
  end

  test "verify! raises Auth::InvalidHmac on bad signature" do
    with_secret do
      req = FakeRequest.new(headers: {}, body: "{}")
      assert_raises(Auth::InvalidHmac) { Auth::HubHmacVerifier.verify!(req) }
    end
  end

  test "verify! returns true on valid signature" do
    with_secret do
      req = signed_request(body: '{"ok":true}')
      assert Auth::HubHmacVerifier.verify!(req)
    end
  end

  test "fails fast when HUB_INGRESS_SECRET env var is missing" do
    prev = ENV["HUB_INGRESS_SECRET"]
    ENV.delete("HUB_INGRESS_SECRET")
    begin
      req = FakeRequest.new(
        headers: { "X-VPI-Signature" => "t=#{Time.now.to_i},v1=abc" },
        body: "{}"
      )
      assert_raises(KeyError) { Auth::HubHmacVerifier.verify(req) }
    ensure
      ENV["HUB_INGRESS_SECRET"] = prev
    end
  end

  test "uses constant-time compare path (does not short-circuit on first byte)" do
    # We cannot directly assert on internal compare timing, but we can
    # verify the public class advertises secure_compare in its
    # implementation by patching SecurityUtils once.
    with_secret do
      req = signed_request(body: "{}")
      called = false
      original = ActiveSupport::SecurityUtils.method(:secure_compare)
      ActiveSupport::SecurityUtils.define_singleton_method(:secure_compare) do |a, b|
        called = true
        original.call(a, b)
      end
      begin
        Auth::HubHmacVerifier.verify(req)
        assert called, "expected ActiveSupport::SecurityUtils.secure_compare to be called"
      ensure
        ActiveSupport::SecurityUtils.singleton_class.send(:remove_method, :secure_compare)
        ActiveSupport::SecurityUtils.define_singleton_method(:secure_compare, original)
      end
    end
  end
end
