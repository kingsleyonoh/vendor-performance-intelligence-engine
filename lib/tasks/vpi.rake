# frozen_string_literal: true

# `bin/rails vpi:setup` — PRD §11.
#
# First-run seed script for a self-hosted VPI install. Behavior:
#
#   1. Ensures `signal_definitions` catalog is seeded (invokes `db:seed`,
#      which is idempotent per `db/seeds.rb`).
#   2. If no tenants exist: creates the "Default" tenant with a freshly-
#      generated API key, prints the raw key ONCE to stdout, stores only
#      the SHA-256 hash + 12-char prefix.
#   3. If tenants already exist: prints "Already initialized..." and exits 0
#      without issuing new keys. Re-runs are idempotent.
#
# Safe to run repeatedly. See `test/tasks/vpi_setup_test.rb` for the
# contract.

namespace :vpi do
  desc "First-run seed: create default tenant + print API key; seed signal_definitions (idempotent)"
  task setup: :environment do
    # Always ensure the signal catalog is up-to-date. `db/seeds.rb` is
    # UPSERT-by-code so this is cheap + idempotent.
    Rake::Task["db:seed"].reenable
    Rake::Task["db:seed"].invoke

    if Tenant.exists?
      existing = Tenant.first
      puts ""
      puts "===================================="
      puts "  Already initialized."
      puts "  Tenant: #{existing.slug} (#{existing.display_name})"
      puts "  Total tenants: #{Tenant.count}"
      puts "  Signal definitions: #{SignalDefinition.count}"
      puts "  Run POST /api/tenants/me/rotate-key to mint a new key."
      puts "===================================="
      puts ""
      next
    end

    key = ::Tenants::ApiKeyGenerator.generate

    tenant = Tenant.create!(
      slug: "default",
      name: "Default",
      legal_name: "Default Tenant",
      full_legal_name: "Default Tenant (initial)",
      display_name: "Default",
      address: { line1: "—", city: "—", country_code: "XX" },
      registration: { tax_id: "—" },
      contact: { email: "admin@example.com" },
      brand_primary_hex: "#0D0D0F",
      brand_accent_hex: "#3B82F6",
      locale: "en-US",
      timezone: "UTC",
      is_active: true,
      api_key_hash: key.api_key_hash,
      api_key_prefix: key.api_key_prefix,
      settings: {}
    )

    ::Audit::Recorder.record(
      actor: "vpi:setup",
      action: "tenant.create",
      entity_type: "Tenant",
      entity_id: tenant.id,
      tenant_id: tenant.id,
      after_state: { slug: tenant.slug }
    )

    # Re-run the seeds after creating the default tenant so the default
    # scoring_rule (PRD §4.7) is seeded for it. `db/seeds.rb` is idempotent
    # upsert-by-(tenant_id, name) so this is safe to run twice.
    Rake::Task["db:seed"].reenable
    Rake::Task["db:seed"].invoke

    puts ""
    puts "===================================="
    puts "  First-run setup complete!"
    puts "  Your API Key: #{key.raw_key}"
    puts "  Use this in the X-API-Key header for all requests."
    puts "  Store it somewhere safe — it is printed only ONCE."
    puts "===================================="
    puts ""
  end
end
