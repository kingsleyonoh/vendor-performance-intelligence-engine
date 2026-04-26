# E2E test task — boots a real Puma and runs `test/e2e_api/*_test.rb` against
# it over real HTTP. See CODING_STANDARDS_TESTING_E2E.md for the E2E contract;
# this is what makes endpoint batches pass the E2E gate.
#
# Usage: `bin/dc bin/rake test:e2e`

# Exclude test/e2e_api/ from the default `bin/rails test` glob. Rails 8's
# runner honours the DEFAULT_TEST_EXCLUDE env var (see
# `Rails::TestUnit::Runner.default_test_exclude_glob`). Mirroring the default
# `test/{system,dummy,fixtures}/**/*_test.rb` exclusion, we add e2e_api so
# that `bin/rails test` never runs E2E without a booted server. The
# explicit `test:e2e` task below sets its own scope.
ENV["DEFAULT_TEST_EXCLUDE"] ||=
  "test/{system,dummy,fixtures,e2e_api}/**/*_test.rb"

namespace :test do
  desc "Boot Puma and run test/e2e_api/*_test.rb against it over real HTTP"
  task :e2e do
    # ServerBoot is plain Ruby — loading :environment would spin the app up
    # twice (once for the rake task, once for the Puma subprocess).
    require_relative "../../test/support/server_boot"

    port = ENV.fetch("E2E_PORT", "3001").to_i

    ServerBoot.boot(port: port) do
      # Run E2E tests inside the booted server's lifespan. Pass the e2e_api
      # dir as an explicit path so Rails' runner doesn't re-apply the default
      # exclude glob set above. `system` returns false on non-zero exit, and
      # we surface that as a rake task failure for CI + the YOLO e2e gate.
      success = system(
        { "E2E_PORT" => port.to_s },
        "bin/rails", "test", "test/e2e_api"
      )
      exit(1) unless success
    end
  end
end
