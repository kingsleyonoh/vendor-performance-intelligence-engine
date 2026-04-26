# frozen_string_literal: true

require "alba"

# Alba serializer for `Vendor` over the API.
#
# Hides the internal fuzzy-match key (`normalized_name`) — it's an index
# column, not a user-facing field. `tenant_id` is implicit in the caller's
# API key and therefore redundant in the body.
class VendorSerializer
  include ::Alba::Resource

  attributes :id,
             :canonical_name,
             :tax_id,
             :country_code,
             :category,
             :annual_spend_cents,
             :currency,
             :status,
             :metadata,
             :created_at,
             :updated_at

  attribute :active_aliases_count do |vendor|
    vendor.vendor_aliases.confirmed.count
  end
end
