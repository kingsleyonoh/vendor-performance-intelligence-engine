# frozen_string_literal: true

require "alba"

# Alba serializer for `RiskAlert` over the API (PRD §8b). The full
# delivery_payload is exposed — operator UIs and audit consumers need
# the snapshot. `tenant_id` is implicit in the caller's API key, so
# omit it from the body.
class RiskAlertSerializer
  include ::Alba::Resource

  attributes :id,
             :vendor_id,
             :previous_band,
             :new_band,
             :previous_score,
             :new_score,
             :direction,
             :status,
             :triggered_by_score,
             :hub_event_id,
             :workflow_execution_id,
             :dispatch_attempts,
             :last_attempt_at,
             :last_error,
             :acknowledged_at,
             :acknowledged_by,
             :resolved_at,
             :suppressed_until,
             :delivery_payload,
             :created_at,
             :updated_at
end
