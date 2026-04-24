# frozen_string_literal: true

# Per-request thread-local store for the currently authenticated tenant
# (and future: the currently authenticated operator user). Set by the
# ApiKeyAuthenticator Rack middleware (future batch) and auto-cleared at
# request end by Rails' CurrentAttributes machinery.
#
# See `.agent/knowledge/foundation/tenant-scoping-pattern.md` for the full
# contract. In short: no controller ever reads `X-API-Key` directly; everyone
# reads `Current.tenant.id`.
class Current < ActiveSupport::CurrentAttributes
  attribute :tenant
  attribute :user
  attribute :request_id
end
