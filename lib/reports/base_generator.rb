# frozen_string_literal: true

require "fileutils"

module Reports
  # Shared scaffold for the four report generators (PRD §5, §13.3).
  # Each generator binds to the FROZEN render_context stored on
  # `vendor_reports.render_context` at the queued → generating transition.
  # NO subclass may issue a database query — the generator consumes the
  # captured snapshot only. This is what guarantees byte-identical
  # re-renders 30 days after original generation (PRD §15 #13).
  #
  # Subclasses implement #render which returns a Hash:
  #
  #   { bytes: <String>, extension: "pdf" | "csv", inline: <Boolean> }
  #
  # The base class handles the file-system write + storage_path update.
  class BaseGenerator
    DEFAULT_STORAGE_PATH = "/var/vpi/reports"
    INLINE_PAYLOAD_MAX_BYTES = 64 * 1024 # 64 KiB

    def self.call(vendor_report:)
      new(vendor_report).call
    end

    def initialize(vendor_report)
      @report = vendor_report
      raw = vendor_report.render_context
      @context = stringify_keys_deep(raw)
    end

    def call
      result = render
      bytes      = result.fetch(:bytes)
      extension  = result.fetch(:extension)
      inline_ok  = result.fetch(:inline, false) && bytes.bytesize <= INLINE_PAYLOAD_MAX_BYTES

      path = storage_path_for(extension)
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, bytes)

      attrs = { storage_path: path }
      attrs[:inline_payload] = bytes if inline_ok
      @report.update!(attrs)
      path
    end

    protected

    def render
      raise NotImplementedError, "#{self.class} must implement #render"
    end

    def f(path, default: ::Reports::StrictFetch::SENTINEL)
      ::Reports::StrictFetch.fetch_path(@context, path, default: default)
    end

    private

    def storage_path_for(extension)
      base = ENV.fetch("REPORT_STORAGE_PATH", DEFAULT_STORAGE_PATH)
      File.join(base, "#{@report.id}.#{extension}")
    end

    # Cast jsonb-loaded hash (string keys) — symbol-keyed hashes (in-memory
    # capture) are also accepted via StrictFetch's symbol/string flexibility.
    # We DO NOT mutate; the input render_context remains as stored.
    def stringify_keys_deep(obj)
      case obj
      when Hash  then obj.each_with_object({}) { |(k, v), out| out[k.to_s] = stringify_keys_deep(v) }
      when Array then obj.map { |v| stringify_keys_deep(v) }
      else            obj
      end
    end
  end
end
