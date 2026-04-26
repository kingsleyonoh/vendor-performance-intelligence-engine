# frozen_string_literal: true

# `bin/rails vpi:demo` — local-only fake-data seeder.
#
# Creates: a UI login user, 8 vendors across categories, signals that drive a
# realistic mix of LOW/MEDIUM/HIGH/CRITICAL scores. Idempotent (matches by
# slug/email/canonical_name).
#
# Run AFTER `bin/rails vpi:setup`. Not for production.

namespace :vpi do
  desc "Local demo data — UI login + fake vendors + signals → scores. Idempotent."
  task demo: :environment do
    tenant = Tenant.find_by(slug: "default")
    abort "Run `bin/rails vpi:setup` first — no `default` tenant" if tenant.nil?
    Current.tenant = tenant

    # 1. UI login user
    email = ENV.fetch("DEMO_EMAIL", "demo@example.com")
    password = ENV.fetch("DEMO_PASSWORD", "demopass123")
    user = User.find_or_initialize_by(email_address: email)
    user.password = password
    user.tenant_id = tenant.id if user.respond_to?(:tenant_id=)
    user.save!

    # 2. Eight vendors with varied profiles
    vendor_specs = [
      { name: "Acme Manufacturing GmbH",     category: "manufacturing",  spend_cents:  4_200_000_00, country: "DE", profile: :good },
      { name: "Globex Industrial Ltd",       category: "manufacturing",  spend_cents:  8_100_000_00, country: "GB", profile: :good },
      { name: "Initech Software Services",   category: "software",       spend_cents:  1_800_000_00, country: "US", profile: :medium },
      { name: "Hooli Cloud Infrastructure",  category: "software",       spend_cents:  3_400_000_00, country: "US", profile: :medium },
      { name: "Soylent Logistics Inc",       category: "logistics",      spend_cents:  2_900_000_00, country: "US", profile: :high },
      { name: "Cyberdyne Components Co",     category: "electronics",    spend_cents:  6_500_000_00, country: "JP", profile: :high },
      { name: "Vandelay Imports SRL",        category: "distribution",   spend_cents:  1_200_000_00, country: "IT", profile: :critical },
      { name: "Pied Piper Networks BV",      category: "telecom",        spend_cents:    750_000_00, country: "NL", profile: :critical }
    ]

    vendors = vendor_specs.map do |spec|
      v = Vendor.find_or_initialize_by(tenant_id: tenant.id, canonical_name: spec[:name])
      v.assign_attributes(
        normalized_name: Ingestion::NameNormalizer.call(spec[:name]),
        category: spec[:category],
        annual_spend_cents: spec[:spend_cents],
        currency: "EUR",
        country_code: spec[:country],
        status: "active"
      )
      v.save!
      [v, spec[:profile]]
    end

    # 3. Signals — value bands per profile drive the score
    # Lower numeric value → less risk for higher_is_worse signals.
    profile_values = {
      good:     { rate: 0.02, count: 0,  duration: 5.0,   flag: false },
      medium:   { rate: 0.20, count: 4,  duration: 25.0,  flag: false },
      high:     { rate: 0.55, count: 12, duration: 60.0,  flag: true  },
      critical: { rate: 1.00, count: 50, duration: 200.0, flag: true  }
    }

    signal_codes = SignalDefinition.pluck(:code, :value_type)
    rand_jitter = ->(base) { (base * (0.85 + rand * 0.30)).round(4) }

    vendors.each do |vendor, profile|
      base = profile_values[profile]

      signal_codes.each do |code, value_type|
        payload = {
          source_system: "manual",
          source_event_id: "demo-#{vendor.id}-#{code}-#{Time.current.to_i}",
          signal_code: code,
          recorded_at: rand(1..14).days.ago.iso8601,
          vendor_ref: { normalized_name: vendor.normalized_name },
          window_start: 14.days.ago.iso8601,
          window_end: Time.current.iso8601
        }

        case value_type
        when "rate"             then payload[:value_numeric] = rand_jitter.call(base[:rate])
        when "count"            then payload[:value_numeric] = (base[:count] * (0.7 + rand * 0.6)).round
        when "duration_seconds" then payload[:value_numeric] = (base[:duration] * 86_400).to_i # days→seconds
        when "boolean"          then payload[:value_boolean] = base[:flag]
        else                          payload[:value_numeric] = rand_jitter.call(base[:rate])
        end

        Ingestion::SignalIngester.call(payload: payload, tenant: tenant)
      end

      # 4. Trigger scoring synchronously so the dashboard has data immediately
      Scoring::CompositeScorer.call(vendor_id: vendor.id, tenant: tenant)
    end

    # 5. Summary
    scores = VendorScore.where(tenant_id: tenant.id).order(computed_at: :desc).index_by(&:vendor_id)
    puts ""
    puts "===================================="
    puts "  Demo data seeded for tenant: #{tenant.display_name}"
    puts "  UI login: #{email} / #{password}"
    puts "  Vendors: #{vendors.size}"
    puts "  Signals: #{VendorSignal.where(tenant_id: tenant.id).count}"
    puts "  Scores:"
    vendors.each do |vendor, _profile|
      s = scores[vendor.id]
      band = s ? s.band.to_s.upcase : "—"
      score = s ? s.composite_score.to_s.rjust(6) : "  —  "
      puts "    #{score}  [#{band.ljust(8)}] #{vendor.canonical_name}"
    end
    puts ""
    puts "  Start the server:  bin/dc bin/dev"
    puts "  Visit:             http://localhost:3000"
    puts "===================================="
    puts ""
  end
end
