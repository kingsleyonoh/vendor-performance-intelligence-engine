# frozen_string_literal: true

# Ecosystem client singletons (PRD §6 + architecture_rules.md "Shared
# infra"). Faraday HTTP clients are held across requests, re-initialized
# on config reload, and gracefully closed on SIGTERM.
#
# Phase 2 batch 015 wires the Notification Hub client. Subsequent
# batches register Workflow Engine, Webhook Engine, Invoice Recon,
# Contract Lifecycle, Transaction Recon, and RAG Platform clients here.

require_relative "../../lib/ecosystem/circuit_breaker"
require_relative "../../lib/ecosystem/hub_client"
require_relative "../../lib/ecosystem/workflow_client"
require_relative "../../lib/ecosystem/webhook_engine_client"
require_relative "../../lib/ecosystem/invoice_recon_client"

Rails.application.config.after_initialize do
  Ecosystem::HubClient.instance           ||= Ecosystem::HubClient.new
  Ecosystem::WorkflowClient.instance      ||= Ecosystem::WorkflowClient.new
  Ecosystem::WebhookEngineClient.instance ||= Ecosystem::WebhookEngineClient.new
  Ecosystem::InvoiceReconClient.instance  ||= Ecosystem::InvoiceReconClient.new
end

# SIGTERM handler — close singletons cleanly when Puma / Sidekiq shut
# down. Best-effort: never raise during shutdown.
at_exit do
  Ecosystem::HubClient.instance&.close
  Ecosystem::WorkflowClient.instance&.close
  Ecosystem::WebhookEngineClient.instance&.close
  Ecosystem::InvoiceReconClient.instance&.close
rescue StandardError
  # swallow: shutting down
end
