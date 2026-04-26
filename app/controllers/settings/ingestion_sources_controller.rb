# frozen_string_literal: true

module Settings
  # Settings → Ingestion Sources UI controller — PRD §8, §13.2.
  #
  # HTML/Turbo surface for operators managing per-tenant adapter
  # configuration. Sibling to `Api::Ingestion::SourcesController` (JSON).
  # Both scope queries on `Current.tenant.id` (set by the Authentication
  # concern via the session row's pinned tenant).
  class IngestionSourcesController < ApplicationController
    before_action :load_source, only: %i[show edit update destroy pull_now]

    def index
      @sources = tenant_scope.order(created_at: :desc)
    end

    def show
      @recent_runs = IngestionRun
                       .where(tenant_id: Current.tenant.id, ingestion_source_id: @source.id)
                       .order(started_at: :desc)
                       .limit(10)
    end

    def new
      @source = IngestionSource.new(tenant: Current.tenant, pull_mode: "periodic", is_enabled: true)
    end

    def edit; end

    def create
      attrs = source_params
      cfg = parse_connection_config(attrs.delete(:connection_config_json))

      contract_input = attrs.merge(connection_config: cfg)
      result = ::Ingestion::SourceContract.new.call(contract_input)
      if result.failure?
        @source = IngestionSource.new(attrs.merge(tenant: Current.tenant))
        @source.errors.add(:base, contract_messages(result))
        return render :new, status: :unprocessable_entity
      end

      @source = IngestionSource.new(
        attrs.merge(tenant: Current.tenant,
                    connection_config: cfg.deep_stringify_keys)
      )
      if @source.save
        redirect_to settings_ingestion_source_path(@source), notice: "Ingestion source created."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def update
      attrs = source_params
      cfg_json = attrs.delete(:connection_config_json)
      cfg = cfg_json.present? ? parse_connection_config(cfg_json) : (@source.connection_config || {})

      merged = {
        source_system:        @source.source_system,
        is_enabled:           attrs.key?(:is_enabled) ? attrs[:is_enabled] : @source.is_enabled,
        connection_config:    cfg,
        pull_mode:            attrs[:pull_mode] || @source.pull_mode,
        pull_interval_minutes: attrs[:pull_interval_minutes] || @source.pull_interval_minutes
      }

      result = ::Ingestion::SourceContract.new.call(merged)
      if result.failure?
        @source.errors.add(:base, contract_messages(result))
        return render :edit, status: :unprocessable_entity
      end

      update_attrs = attrs.except(:source_system).merge(connection_config: cfg.deep_stringify_keys)
      if @source.update(update_attrs)
        redirect_to settings_ingestion_source_path(@source), notice: "Ingestion source saved."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @source.update_columns(is_enabled: false, updated_at: Time.now.utc)
      redirect_to settings_ingestion_sources_path, notice: "Ingestion source disabled."
    end

    # POST /settings/ingestion-sources/:id/pull_now
    def pull_now
      unless @source.is_enabled
        redirect_to settings_ingestion_source_path(@source),
                    alert: "Cannot pull from a disabled source. Enable it first." and return
      end

      if IngestionRun.where(tenant_id: Current.tenant.id,
                            ingestion_source_id: @source.id,
                            status: "running").exists?
        redirect_to settings_ingestion_source_path(@source),
                    alert: "An ingestion run is already in progress." and return
      end

      job_class_name = ::Api::Ingestion::Sources::PullNowController::ADAPTER_JOBS[@source.source_system]
      unless job_class_name
        redirect_to settings_ingestion_source_path(@source),
                    alert: "Pull job not yet implemented for #{@source.source_system}." and return
      end

      run = IngestionRun.create!(
        tenant: Current.tenant,
        ingestion_source: @source,
        mode: "manual",
        status: "running",
        started_at: Time.now.utc
      )

      job_class_name.constantize.perform_later(@source.id, run.id)

      redirect_to settings_ingestion_source_path(@source),
                  notice: "Pull queued. Run #{run.id[0, 8]} is running."
    end

    private

    def tenant_scope
      IngestionSource.where(tenant_id: Current.tenant.id)
    end

    def load_source
      @source = tenant_scope.find_by(id: params[:id])
      return if @source

      redirect_to settings_ingestion_sources_path, alert: "Ingestion source not found."
    end

    def source_params
      raw = params.require(:ingestion_source).permit(
        :source_system, :is_enabled, :pull_mode, :pull_interval_minutes,
        :connection_config_json
      ).to_h.symbolize_keys
      raw[:is_enabled] = ActiveModel::Type::Boolean.new.cast(raw[:is_enabled]) if raw.key?(:is_enabled)
      raw[:pull_interval_minutes] = raw[:pull_interval_minutes].to_i if raw[:pull_interval_minutes].present?
      raw
    end

    def parse_connection_config(json_str)
      return {} if json_str.blank?
      JSON.parse(json_str)
    rescue JSON::ParserError
      {}
    end

    def contract_messages(result)
      ::Ingestion::SourceContract.details_for(result)
        .map { |d| "#{d[:path]}: #{d[:issue]}" }.join("; ")
    end
  end
end
