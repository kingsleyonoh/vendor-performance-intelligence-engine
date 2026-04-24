# frozen_string_literal: true

require "alba"

# Alba serializer for `VendorSignal` over the API (PRD §8b).
#
# Internal columns NOT exposed:
#   - supersedes_id (internal corrections pointer)
#   - raw_payload (upstream raw body; may contain unrelated PII)
#   - rejection_reason (only meaningful for rejected rows; included when set)
class VendorSignalSerializer
  include ::Alba::Resource

  attributes :id,
             :tenant_id,
             :vendor_id,
             :signal_code,
             :source_system,
             :source_event_id,
             :value_numeric,
             :value_boolean,
             :context,
             :window_start,
             :window_end,
             :recorded_at,
             :status,
             :rejection_reason,
             :created_at
end
