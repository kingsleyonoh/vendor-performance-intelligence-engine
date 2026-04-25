# frozen_string_literal: true

require "concurrent"

module Ecosystem
  # Raised when the circuit is OPEN — calls short-circuit instead of
  # hitting the wire. Caller (Faraday-using HubClient, etc.) should
  # treat this as equivalent to a transient ecosystem outage and let
  # Sidekiq retry the enqueuing job after the breaker re-closes.
  class CircuitOpen < StandardError; end

  # Tiny rolling-window failure counter / circuit breaker for
  # ecosystem HTTP clients (PRD §6 — "circuit breaker per adapter").
  #
  # Three states:
  #   - :closed   → calls pass through; failures recorded in a sliding
  #                 window. ≥failure_threshold consecutive failures inside
  #                 the window → :open.
  #   - :open     → calls short-circuit with `CircuitOpen` until
  #                 cooldown_seconds elapses → :half_open.
  #   - :half_open → next call goes through; success closes, failure
  #                 re-opens.
  #
  # Thread-safe via `Concurrent::AtomicReference` — one instance per
  # adapter, held in the singleton initialized at boot. Pure Ruby; no
  # gem dependency beyond `concurrent-ruby` (already a Rails dep).
  class CircuitBreaker
    DEFAULTS = {
      failure_threshold: 5,
      window_seconds:    60,
      cooldown_seconds:  60
    }.freeze

    State = Struct.new(:status, :failures, :opened_at, keyword_init: true)

    def initialize(failure_threshold: DEFAULTS[:failure_threshold],
                   window_seconds:    DEFAULTS[:window_seconds],
                   cooldown_seconds:  DEFAULTS[:cooldown_seconds],
                   clock:             -> { Time.now })
      @failure_threshold = failure_threshold
      @window_seconds    = window_seconds
      @cooldown_seconds  = cooldown_seconds
      @clock             = clock
      @state = Concurrent::AtomicReference.new(
        State.new(status: :closed, failures: [], opened_at: nil)
      )
    end

    # Wraps a block. If the breaker is OPEN beyond cooldown, transitions
    # to HALF_OPEN and lets the block run as a probe. The block must
    # raise on transient failures; non-raising returns are treated as
    # success.
    def call
      transition_if_cooldown_elapsed
      raise CircuitOpen, "circuit open" if status == :open

      begin
        result = yield
      rescue StandardError => e
        record_failure
        raise e
      end
      record_success
      result
    end

    def status
      @state.get.status
    end

    # Hand-resettable for tests + admin-grade recovery.
    def reset!
      @state.set(State.new(status: :closed, failures: [], opened_at: nil))
    end

    private

    def now
      @clock.call
    end

    def record_failure
      @state.update do |st|
        # Drop failures older than the window.
        recent = (st.failures + [now]).select { |t| now - t <= @window_seconds }
        if recent.size >= @failure_threshold
          State.new(status: :open, failures: recent, opened_at: now)
        else
          State.new(status: st.status, failures: recent, opened_at: st.opened_at)
        end
      end
    end

    def record_success
      @state.update do |st|
        # Half-open success → fully reset. Closed success → just clear
        # the failure window (so a single later failure doesn't tip the
        # threshold from a stale count).
        State.new(status: :closed, failures: [], opened_at: nil)
      end
    end

    def transition_if_cooldown_elapsed
      st = @state.get
      return unless st.status == :open
      return unless st.opened_at && (now - st.opened_at >= @cooldown_seconds)

      @state.update do |s|
        if s.status == :open && s.opened_at && (now - s.opened_at >= @cooldown_seconds)
          State.new(status: :half_open, failures: s.failures, opened_at: s.opened_at)
        else
          s
        end
      end
    end
  end
end
