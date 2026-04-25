# frozen_string_literal: true

require "prometheus/client/formats/text"

# /metrics — Prometheus scrape endpoint, PRD §10b.
#
# Public-allowlisted in `Auth::ApiKeyAuthenticator` (no X-API-Key required).
# Gated by HTTP Basic Auth — credentials come from
# METRICS_BASIC_AUTH_USER + METRICS_BASIC_AUTH_PASS env vars. When
# PROMETHEUS_ENABLED=false the endpoint 404s.
#
# Prometheus exposition (text/plain; version=0.0.4) so a self-hosted
# Prometheus on the same VPC can scrape directly without a sidecar.
class MetricsController < ActionController::API
  include ActionController::HttpAuthentication::Basic::ControllerMethods

  before_action :enforce_feature_flag!
  before_action :authenticate_metrics_user!

  def index
    Vpi::Metrics.refresh_sampled!
    body = ::Prometheus::Client::Formats::Text.marshal(Vpi::Metrics.registry)
    render plain: body, content_type: "text/plain; version=0.0.4; charset=utf-8"
  end

  private

  def enforce_feature_flag!
    return if ENV.fetch("PROMETHEUS_ENABLED", "false") == "true"

    head :not_found
  end

  def authenticate_metrics_user!
    expected_user = ENV["METRICS_BASIC_AUTH_USER"].to_s
    expected_pass = ENV["METRICS_BASIC_AUTH_PASS"].to_s

    authenticate_or_request_with_http_basic("Metrics") do |user, pass|
      ActiveSupport::SecurityUtils.secure_compare(user.to_s, expected_user) &
        ActiveSupport::SecurityUtils.secure_compare(pass.to_s, expected_pass)
    end
  end
end
