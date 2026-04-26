# frozen_string_literal: true

require "test_helper"

# Axiom log shipping — PRD §10b.
#
# Axiom does NOT publish a canonical Ruby SDK gem. The chosen integration
# path is a Logger formatter that posts JSON batches to Axiom's HTTP ingest
# API. When AXIOM_TOKEN or AXIOM_DATASET is unset, the shipper is a no-op
# (standalone-first invariant).
#
# Failure to ship to Axiom MUST NEVER crash the request — the shipper
# rescues StandardError on every emit.
class AxiomInitializerTest < ActiveSupport::TestCase
  def setup
    @original_token   = ENV["AXIOM_TOKEN"]
    @original_dataset = ENV["AXIOM_DATASET"]
  end

  def teardown
    ENV["AXIOM_TOKEN"]   = @original_token
    ENV["AXIOM_DATASET"] = @original_dataset
    Vpi::AxiomShipper.reset! if defined?(Vpi::AxiomShipper)
    Vpi::AxiomShipper.instance_variable_set(:@test_post, nil) if defined?(Vpi::AxiomShipper)
    Vpi::AxiomShipper.instance_variable_set(:@test_rand, nil) if defined?(Vpi::AxiomShipper)
  end

  test "shipper.enabled? is false when AXIOM_TOKEN is unset" do
    ENV.delete("AXIOM_TOKEN")
    ENV["AXIOM_DATASET"] = "vpi-test"
    Vpi::AxiomShipper.reset!
    refute Vpi::AxiomShipper.enabled?
  end

  test "shipper.enabled? is false when AXIOM_DATASET is unset" do
    ENV["AXIOM_TOKEN"] = "xaat-token"
    ENV.delete("AXIOM_DATASET")
    Vpi::AxiomShipper.reset!
    refute Vpi::AxiomShipper.enabled?
  end

  test "shipper.enabled? is true when both AXIOM_TOKEN and AXIOM_DATASET set" do
    ENV["AXIOM_TOKEN"]   = "xaat-token"
    ENV["AXIOM_DATASET"] = "vpi-test"
    Vpi::AxiomShipper.reset!
    assert Vpi::AxiomShipper.enabled?
  end

  test "ship is a no-op when disabled (no HTTP call)" do
    ENV.delete("AXIOM_TOKEN")
    Vpi::AxiomShipper.reset!
    assert_nil Vpi::AxiomShipper.ship({ message: "hello" })
  end

  test "ship swallows network failures rather than raising" do
    ENV["AXIOM_TOKEN"]   = "xaat-token"
    ENV["AXIOM_DATASET"] = "vpi-test"
    Vpi::AxiomShipper.reset!

    Vpi::AxiomShipper.instance_variable_set(:@test_post, ->(_payload) { raise ::Faraday::ConnectionFailed.new("boom") })

    assert_nothing_raised do
      Vpi::AxiomShipper.ship({ message: "hello" })
    end
  end

  test "ship samples 1 in 10 INFO-level events but ships all WARN/ERROR" do
    ENV["AXIOM_TOKEN"]   = "xaat-token"
    ENV["AXIOM_DATASET"] = "vpi-test"
    Vpi::AxiomShipper.reset!

    sent = 0
    Vpi::AxiomShipper.instance_variable_set(:@test_post, ->(_payload) { sent += 1 })

    # 100 ERROR events MUST all ship.
    100.times { Vpi::AxiomShipper.ship({ level: "ERROR", message: "x" }) }
    assert_equal 100, sent

    # rand < 0.1 → sampled in
    sent = 0
    Vpi::AxiomShipper.instance_variable_set(:@test_rand, 0.05)
    100.times { Vpi::AxiomShipper.ship({ level: "INFO", message: "x" }) }
    assert_equal 100, sent

    # rand >= 0.1 → sampled out
    sent = 0
    Vpi::AxiomShipper.instance_variable_set(:@test_rand, 0.5)
    100.times { Vpi::AxiomShipper.ship({ level: "INFO", message: "x" }) }
    assert_equal 0, sent
  end
end
