# frozen_string_literal: true

module Reports
  # ERB-side strict-undefined path resolver. Backs every report ERB
  # template (PRD §5.6 / §13.3) so a missing token NEVER silently
  # renders an empty string — it raises and fails the render. CI's
  # template-lint test (Phase 3 follow-up batch) leverages this to
  # ensure every fixture-context pairing covers every token used by
  # every template.
  #
  # Usage in ERB:
  #
  #   <%= f(@context, "tenant.legal_name") %>
  #   <%= f(@context, "data.vendor.canonical_name") %>
  #   <%= f(@context, "tenant.contact.fax", default: "—") %>
  #   <%= f(@context, "data.score_history[0].composite_score") %>
  #
  # The shortcut `f(...)` is exposed via `app/helpers/reports_helper.rb`.
  module StrictFetch
    # Raised when a path cannot be resolved. Defined inside StrictFetch
    # (rather than at the Reports namespace level) so Zeitwerk's
    # file-per-constant autoload finds it via lib/reports/strict_fetch.rb.
    # The legacy alias `Reports::StrictFetchError` is kept for ERGO via
    # an explicit constant assignment below.
    class FetchError < StandardError; end
    # Match a bracket index suffix e.g. `score_history[3]`.
    BRACKET_RE = /\A(?<key>[^\[\]]+)\[(?<idx>\d+)\]\z/

    SENTINEL = Object.new.freeze

    def self.fetch_path(context, path, default: SENTINEL)
      raise ArgumentError, "context cannot be nil" if context.nil?
      raise ArgumentError, "path cannot be empty"  if path.nil? || path.to_s.strip.empty?

      segments = path.to_s.split(".")
      cursor = context

      segments.each do |raw_segment|
        m = BRACKET_RE.match(raw_segment)
        if m
          cursor = walk_hash(cursor, m[:key], path)
          cursor = walk_array(cursor, m[:idx].to_i, path) unless cursor.equal?(SENTINEL)
        else
          cursor = walk_hash(cursor, raw_segment, path)
        end

        if cursor.equal?(SENTINEL) || cursor.nil?
          return default unless default.equal?(SENTINEL)

          raise FetchError,
                "StrictFetchError: missing path `#{path}` (segment `#{raw_segment}` did not resolve)"
        end
      end

      cursor
    end

    # Internal — pull a key off a Hash, supporting either symbol or string
    # keys. Returns SENTINEL if the cursor is not a Hash or the key is
    # missing.
    def self.walk_hash(cursor, key, _full_path)
      return SENTINEL unless cursor.is_a?(Hash)

      if cursor.key?(key.to_sym)
        cursor[key.to_sym]
      elsif cursor.key?(key.to_s)
        cursor[key.to_s]
      else
        SENTINEL
      end
    end

    # Internal — pull an index off an Array. Returns SENTINEL on out-of-bounds.
    def self.walk_array(cursor, idx, _full_path)
      return SENTINEL unless cursor.is_a?(Array)
      return SENTINEL if idx >= cursor.length

      cursor[idx]
    end

    private_class_method :walk_hash, :walk_array
  end

  # Public alias — usable as `Reports::StrictFetchError` from ERB
  # templates and call sites that don't want to type the nested form.
  StrictFetchError = StrictFetch::FetchError
end
