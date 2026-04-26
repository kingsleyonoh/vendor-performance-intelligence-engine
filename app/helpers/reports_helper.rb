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

  # Status pill colors for the reports index table.
  STATUS_BG = {
    "queued"     => "#FEF3C7",
    "generating" => "#DBEAFE",
    "ready"      => "#C6F6D5",
    "failed"     => "#FED7D7",
    "expired"    => "#E2E8F0"
  }.freeze
  STATUS_FG = {
    "queued"     => "#92400E",
    "generating" => "#1E40AF",
    "ready"      => "#22543D",
    "failed"     => "#742A2A",
    "expired"    => "#4A5568"
  }.freeze

  def status_bg(status)
    STATUS_BG.fetch(status.to_s, "#E2E8F0")
  end

  def status_fg(status)
    STATUS_FG.fetch(status.to_s, "#1A202C")
  end
end
