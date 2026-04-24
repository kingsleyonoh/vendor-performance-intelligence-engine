# frozen_string_literal: true

require "alba"

# Alba serializer for `Tenant` records exposed over the API
# (`GET /api/tenants/me`, `POST /api/tenants/register`).
#
# CRITICAL: `api_key_hash` and `api_key_prefix` are NEVER serialized. The
# raw API key is only ever returned in the `api_key` top-level field of
# the register / rotate-key responses, not through this serializer.
class TenantSerializer
  include ::Alba::Resource

  attributes :id,
             :slug,
             :legal_name,
             :full_legal_name,
             :display_name,
             :address,
             :registration,
             :contact,
             :wordmark_url,
             :brand_primary_hex,
             :brand_accent_hex,
             :locale,
             :timezone,
             :is_active,
             :created_at,
             :updated_at
end
