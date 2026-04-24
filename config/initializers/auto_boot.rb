# frozen_string_literal: true

# Auto-boot hook — PRD §11 + §14.
#
# Reads `AUTO_MIGRATE` / `AUTO_SEED` env vars at Rails boot and runs the
# corresponding rake tasks inline. Intended for the self-hosted first-run
# flow ("`docker compose up` and it works"); no-ops in dev/test unless
# flags are set explicitly.
#
# Idempotent by construction:
#   - `db:migrate` skips already-applied migrations.
#   - `vpi:setup` detects existing tenants and exits without re-issuing keys.
#
# Verified by `test/integration/auto_boot_test.rb`.

module AutoBoot
  module_function

  def run
    run_migrations if migrate_enabled?
    run_seed       if seed_enabled?
  end

  def run_migrations
    require "rake"
    Rails.application.load_tasks unless Rake::Task.task_defined?("db:migrate")
    Rake::Task["db:migrate"].reenable
    Rake::Task["db:migrate"].invoke
  end

  def run_seed
    require "rake"
    Rails.application.load_tasks unless Rake::Task.task_defined?("vpi:setup")
    Rake::Task["vpi:setup"].reenable
    Rake::Task["vpi:setup"].invoke
  end

  def migrate_enabled?
    ENV.fetch("AUTO_MIGRATE", "false").to_s.downcase == "true"
  end

  def seed_enabled?
    ENV.fetch("AUTO_SEED", "false").to_s.downcase == "true"
  end
end

# Run inside an after_initialize hook so the Rails environment (ActiveRecord
# connections, autoloaders) is fully booted before we touch rake tasks. The
# hook is a no-op when both flags are off (default in dev/test).
Rails.application.config.after_initialize do
  AutoBoot.run if AutoBoot.migrate_enabled? || AutoBoot.seed_enabled?
end
