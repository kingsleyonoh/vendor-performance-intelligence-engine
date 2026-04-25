# frozen_string_literal: true

require "alba"

# Alba serializer for `VendorReport` over the API (PRD §8b, §13.3).
#
# `render_context` is excluded by default (heavy payload — can be many KB).
# Pass `include_context: true` (via params[:include_context]) at the
# controller layer to include it; controllers serialize a one-off shape.
# `inline_payload` and `tenant_snapshot` are exposed as the
# tenant_snapshot is part of the legal-defensibility surface.
class VendorReportSerializer
  include ::Alba::Resource

  attributes :id,
             :vendor_id,
             :report_type,
             :status,
             :output_format,
             :parameters,
             :tenant_snapshot,
             :storage_path,
             :requested_by_user_id,
             :generated_at,
             :expires_at,
             :error_summary,
             :created_at,
             :updated_at
end
