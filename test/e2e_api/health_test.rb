require "test_helper"
require "net/http"
require "uri"

# E2E smoke — hits a RUNNING Puma via real HTTP (not an in-process test client).
# The `test:e2e` rake task in lib/tasks/test.rake boots Puma via ServerBoot and
# runs this file. See CODING_STANDARDS_TESTING_E2E.md for why E2E must go over
# real HTTP (catches Rack middleware ordering, CORS, startup, Traefik routing
# that integration tests miss).
class HealthE2ETest < ActiveSupport::TestCase
  # Parallelization would race a single shared server on one port. Keep E2E
  # sequential; the suite is tiny (this is a smoke harness).
  self.test_order = :sorted
  parallelize(workers: 1)

  def setup
    @port = ENV.fetch("E2E_PORT", "3001").to_i
  end

  test "GET /up against running Puma returns 200" do
    uri = URI("http://127.0.0.1:#{@port}/up")
    response = Net::HTTP.get_response(uri)
    assert_equal "200", response.code, "Expected 200 from /up, got #{response.code}: #{response.body}"
  end
end
