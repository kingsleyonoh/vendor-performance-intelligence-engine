# frozen_string_literal: true

# RagEnrichmentJob — PRD §5.7, §6.7, §7, §13.3.
#
# Nightly cron (`0 3 * * *` UTC). For each Vendor with
# `metadata.rag_document_count > 0`, calls
# `Ecosystem::RagPlatformClient#fetch_entities(name: vendor.normalized_name)`
# and stores `{entities: [...], fetched_at: <iso8601>}` under
# `vendors.metadata.rag_enrichment`.
#
# Standalone-first (PRD §2.2): when `RAG_PLATFORM_ENABLED != "true"`, the
# job runs but does no network calls and writes nothing.
#
# Per-vendor error trapping: TransientFailure / CircuitOpen / generic
# StandardError on one vendor logs and continues to the next. The engine
# never fails on RAG downtime (PRD §6.7 invariant).
class RagEnrichmentJob < ApplicationJob
  queue_as :default

  def perform
    rag = rag_client
    return Rails.logger.warn("[rag_enrichment] RAG_PLATFORM_ENABLED=false — skipping") unless rag.enabled?

    vendors_to_enrich.find_each do |vendor|
      enrich_vendor!(vendor: vendor, rag: rag)
    rescue StandardError => e
      Rails.logger.error("[rag_enrichment] vendor=#{vendor.id} failed: #{e.class}: #{e.message}")
    end
  end

  private

  # All active vendors with at least one document indexed in the RAG
  # Platform. Indexed-state is tracked locally via
  # `vendors.metadata.rag_document_count` (per PRD §5.7), set by an
  # external upload flow. Vendors without that flag are skipped — there
  # is nothing for the RAG graph to enrich.
  def vendors_to_enrich
    Vendor
      .where(status: "active")
      .where("(metadata ->> 'rag_document_count')::int > 0")
  end

  def enrich_vendor!(vendor:, rag:)
    result = rag.fetch_entities(name: vendor.normalized_name)

    case result[:status]
    when :ok
      write_enrichment!(vendor: vendor, entities: result[:entities] || [])
    when :failed
      Rails.logger.warn(
        "[rag_enrichment] vendor=#{vendor.id} non-retryable failure: " \
        "#{result[:response_code]} #{result[:error]}"
      )
    when :skipped
      # Should not normally hit this branch (we checked enabled? upfront),
      # but log defensively in case the flag flipped mid-run.
      Rails.logger.warn("[rag_enrichment] vendor=#{vendor.id} skipped: #{result[:reason]}")
    end
  rescue Ecosystem::TransientFailure, Ecosystem::CircuitOpen => e
    # 5xx-after-retries or breaker-open. PRD §6.7: never fail the engine
    # on RAG downtime — log and let the next nightly run retry.
    Rails.logger.warn("[rag_enrichment] vendor=#{vendor.id} transient: #{e.class}: #{e.message}")
  end

  def write_enrichment!(vendor:, entities:)
    fetched_at = Time.now.utc.iso8601
    payload = {
      "entities"   => entities,
      "fetched_at" => fetched_at
    }
    new_metadata = (vendor.metadata || {}).merge("rag_enrichment" => payload)
    vendor.update_columns(metadata: new_metadata, updated_at: Time.current)
  end

  def rag_client
    Ecosystem::RagPlatformClient.instance || Ecosystem::RagPlatformClient.new
  end
end
