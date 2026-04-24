# frozen_string_literal: true

module Api
  # CRUD for /api/vendors/:vendor_id/aliases + the top-level pending queue
  # at /api/aliases/pending — PRD §8b.
  class VendorAliasesController < ::Api::BaseController
    CREATE_ATTRS = %i[source_system source_ref alias_text confidence is_confirmed].freeze
    UPDATE_ATTRS = %i[alias_text confidence is_confirmed].freeze

    before_action :load_vendor, only: %i[index show create update destroy]
    before_action :load_alias, only: %i[show update destroy]

    def index
      authorize! VendorAlias, with: VendorAliasPolicy
      aliases = @vendor.vendor_aliases.order(created_at: :desc)
      render json: { aliases: VendorAliasSerializer.new(aliases).serializable_hash }, status: :ok
    end

    def show
      authorize! @alias, with: VendorAliasPolicy
      render json: { alias: VendorAliasSerializer.new(@alias).serializable_hash }, status: :ok
    end

    def create
      authorize! VendorAlias, with: VendorAliasPolicy

      attrs = create_params
      alias_record = @vendor.vendor_aliases.new(
        tenant: Current.tenant,
        source_system: attrs[:source_system],
        source_ref: attrs[:source_ref],
        alias_text: attrs[:alias_text],
        confidence: attrs.key?(:confidence) ? attrs[:confidence] : 1.0,
        is_confirmed: attrs.key?(:is_confirmed) ? attrs[:is_confirmed] : true
      )

      if alias_record.save
        render json: { alias: VendorAliasSerializer.new(alias_record).serializable_hash }, status: :created
      else
        render_model_validation_error(alias_record)
      end
    end

    def update
      authorize! @alias, with: VendorAliasPolicy

      if @alias.update(update_params)
        render json: { alias: VendorAliasSerializer.new(@alias).serializable_hash }, status: :ok
      else
        render_model_validation_error(@alias)
      end
    end

    def destroy
      authorize! @alias, with: VendorAliasPolicy

      @alias.destroy!
      render json: { alias: VendorAliasSerializer.new(@alias).serializable_hash }, status: :ok
    end

    # Top-level pending-review queue across all vendors in the caller's tenant.
    # GET /api/aliases/pending
    def pending
      authorize! VendorAlias, with: VendorAliasPolicy

      aliases = VendorAlias
        .where(tenant_id: Current.tenant.id)
        .pending
        .order(created_at: :desc)

      render json: { aliases: VendorAliasSerializer.new(aliases).serializable_hash }, status: :ok
    end

    private

    def load_vendor
      @vendor = Vendor.where(tenant_id: Current.tenant.id).find(params[:vendor_id])
    end

    def load_alias
      @alias = @vendor.vendor_aliases.find(params[:id])
    end

    def create_params
      body = request_body
      body.slice(*CREATE_ATTRS)
    end

    def update_params
      body = request_body
      body.slice(*UPDATE_ATTRS)
    end

    def request_body
      raw = request.request_parameters
      raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
      inner = raw["alias"] || raw[:alias] || raw
      inner.deep_symbolize_keys
    rescue StandardError
      {}
    end

    def render_model_validation_error(record)
      details = record.errors.map { |err| { path: err.attribute.to_s, issue: err.message } }
      render_api_error(
        ::Errors::JsonApiError::VALIDATION_ERROR,
        message: "Validation failed.",
        details: details
      )
    end
  end
end
