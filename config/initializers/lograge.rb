# frozen_string_literal: true

# Structured logging for Axiom ingestion (PRD §10b). One JSON line per request
# with method, path, controller, action, status, duration, plus the VPI-
# specific fields required for multi-tenant observability:
#
# - request_id: ties log lines + audit rows + Sentry events to one request
# - tenant_id:  set by `Current.tenant` after ApiKeyAuthenticator middleware
#               runs (Phase 1); nil for public endpoints + UI requests until
#               tenant-scoped UI lands
# - user_id:    set by `Current.user` for UI (session-auth) requests
# - params:     request params with Rails' standard noise filtered out
# - exception:  class name when the controller raised (lograge populates
#               event.payload[:exception] as [class_name, message])
#
# Axiom token + dataset wiring lands in Phase 3. This initializer only
# establishes the SHAPE so every controller written after Batch 005 emits
# the right fields from the first commit.
Rails.application.configure do
  config.lograge.enabled = true
  config.lograge.formatter = Lograge::Formatters::Json.new
  config.lograge.base_controller_class = ["ActionController::Base", "ActionController::API"]

  config.lograge.custom_options = lambda do |event|
    # request_id is propagated two ways:
    # 1. For app controllers (ApplicationController / Api::BaseController),
    #    a before_action copies `request.request_id` -> `Current.request_id`.
    # 2. For gem controllers that bypass those base classes (e.g.
    #    `Rails::HealthController#show` at `/up`), lograge's event
    #    payload carries `request_id` via a tiny instrumentation shim in
    #    `config/initializers/request_id_instrumentation.rb`.
    request_id = (Current.respond_to?(:request_id) && Current.request_id) ||
                 event.payload[:request_id]

    {
      request_id: request_id,
      tenant_id: Current.respond_to?(:tenant) ? Current.tenant&.id : nil,
      user_id: Current.respond_to?(:user) ? Current.user&.id : nil,
      params: event.payload[:params]&.except("controller", "action", "format", "authenticity_token"),
      exception: event.payload[:exception]&.first
    }.compact
  end
end
