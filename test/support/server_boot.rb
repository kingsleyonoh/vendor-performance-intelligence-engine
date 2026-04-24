require "net/http"
require "uri"

# Boots a real Puma server via `bin/rails server` on a dedicated port, waits
# for `/up` readiness, yields to the caller (who runs E2E tests against it),
# and guarantees a clean SIGTERM shutdown on the way out.
#
# This is distinct from Rails' in-process `ActionDispatch::IntegrationTest`:
# E2E tests under `test/e2e_api/` hit a running server over real HTTP, which
# is what `CODING_STANDARDS_TESTING_E2E.md` mandates for endpoint batches.
# The `test:e2e` rake task (lib/tasks/test.rake) wraps this helper.
module ServerBoot
  extend self

  DEFAULT_PORT = 3001
  READINESS_TIMEOUT_SECONDS = 30

  # Boots Puma, waits for readiness, yields the pid, then cleans up.
  #   ServerBoot.boot(port: 3001) { |pid| run_tests }
  def boot(port: DEFAULT_PORT)
    pid = spawn_server(port)
    wait_ready("http://127.0.0.1:#{port}/up", timeout: READINESS_TIMEOUT_SECONDS)
    yield pid
  ensure
    shutdown(pid) if pid
  end

  private

  def spawn_server(port)
    env = { "RAILS_ENV" => "test", "PORT" => port.to_s }
    Process.spawn(
      env,
      "bin/rails", "server", "-p", port.to_s, "-b", "127.0.0.1",
      out: File::NULL, err: File::NULL
    )
  end

  def wait_ready(url, timeout:)
    deadline = Time.now + timeout
    uri = URI(url)
    until Time.now > deadline
      begin
        response = Net::HTTP.start(uri.host, uri.port, open_timeout: 1, read_timeout: 2) do |http|
          http.get(uri.request_uri)
        end
        return true if response.code == "200"
      rescue StandardError
        # Server not up yet; retry until deadline.
      end
      sleep 0.5
    end
    raise "Puma did not become ready on #{url} within #{timeout}s"
  end

  def shutdown(pid)
    Process.kill("TERM", pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    # Already gone — nothing to clean up.
  end
end
