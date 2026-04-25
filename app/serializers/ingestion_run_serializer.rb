# frozen_string_literal: true

require "alba"

# Alba serializer for `IngestionRun` — PRD §8b. Read-only audit shape;
# tenant_id implicit in the API-key holder so omitted from response body.
class IngestionRunSerializer
  include ::Alba::Resource

  attributes :id,
             :ingestion_source_id,
             :mode,
             :status,
             :signals_attempted,
             :signals_stored,
             :signals_rejected,
             :signals_deduped,
             :error_summary,
             :retry_payload,
             :started_at,
             :finished_at,
             :created_at,
             :updated_at
end
