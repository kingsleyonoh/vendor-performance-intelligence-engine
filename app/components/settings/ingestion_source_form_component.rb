# frozen_string_literal: true

module Settings
  # Shared form for new + edit ingestion source. Renders fields for
  # source_system (only on new), pull_mode, pull_interval_minutes,
  # is_enabled, and a connection_config JSON textarea.
  #
  # Secret-ref enforcement happens server-side in `Ingestion::SourceContract`.
  # The form copy walks the operator through the ENV: pattern.
  class IngestionSourceFormComponent < ViewComponent::Base
    def initialize(source:, mode:)
      @source = source
      @mode = mode # :new or :edit
    end

    attr_reader :source, :mode

    def form_url
      mode == :new ? helpers.settings_ingestion_sources_path : helpers.settings_ingestion_source_path(source)
    end

    def form_method
      mode == :new ? :post : :patch
    end

    def submit_label
      mode == :new ? "Create" : "Save"
    end

    def connection_config_json
      JSON.pretty_generate(source.connection_config || {})
    rescue StandardError
      "{}"
    end

    def source_system_options
      IngestionSource::SOURCE_SYSTEMS
    end

    def pull_mode_options
      IngestionSource::PULL_MODES
    end
  end
end
