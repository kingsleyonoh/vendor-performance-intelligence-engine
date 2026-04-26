# frozen_string_literal: true

# Per-request thread-local store. Set by:
#
# - `lib/auth/api_key_authenticator.rb` (Phase 1) -> sets `Current.tenant`
#   from the `X-API-Key` header for `/api/*` requests.
# - `app/controllers/concerns/authentication.rb` (Rails 8 built-in auth)
#   -> sets `Current.session` from the session cookie for UI requests. The
#   delegated `Current.user` is the authenticated operator.
# - `ActionDispatch::RequestId` middleware -> propagates `Current.request_id`
#   for logging + audit correlation.
#
# Auto-cleared at request end by Rails' CurrentAttributes machinery.
#
# See `.agent/knowledge/foundation/tenant-scoping-pattern.md` +
# `.agent/knowledge/foundation/session-auth-pattern.md` for the full
# contract. In short: no controller ever reads `X-API-Key` directly; every
# API caller reads `Current.tenant.id`. No UI controller reads the session
# cookie directly; every UI caller reads `Current.user`.
class Current < ActiveSupport::CurrentAttributes
  # UI auth (Rails 8 built-in)
  attribute :session
  delegate :user, to: :session, allow_nil: true

  # API auth + logging (VPI-specific)
  attribute :tenant
  attribute :request_id
end
