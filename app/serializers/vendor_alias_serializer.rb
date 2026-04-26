# frozen_string_literal: true

require "alba"

# Alba serializer for `VendorAlias`. Returned nested under `/api/vendors/:id/aliases`
# + the top-level `/api/aliases/pending` queue.
class VendorAliasSerializer
  include ::Alba::Resource

  attributes :id,
             :vendor_id,
             :source_system,
             :source_ref,
             :alias_text,
             :confidence,
             :is_confirmed,
             :created_at,
             :updated_at
end
