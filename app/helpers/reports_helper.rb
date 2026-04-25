# frozen_string_literal: true

# Helper exposed to ERB report templates (PRD §5.6 / §13.3). Every report
# template binds to the FROZEN `vendor_reports.render_context` JSON via
# `f(context, "path.to.field")`, which raises `Reports::StrictFetchError`
# if the path is unmapped. CI's template-lint test (Phase 3 follow-up
# batch) leverages this to ensure every fixture pairing covers every
# token every template references.
module ReportsHelper
  # Shortcut for `Reports::StrictFetch.fetch_path`. Used in
  # `app/views/reports/*.erb`.
  def f(context, path, default: ::Reports::StrictFetch::SENTINEL)
    ::Reports::StrictFetch.fetch_path(context, path, default: default)
  end
end
