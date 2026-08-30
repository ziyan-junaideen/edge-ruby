# frozen_string_literal: true

require "time"

module Edge
  # Decides whether a failed request may be sent again, and how long to wait.
  #
  # The default is deliberately narrow: **reads retry, writes do not.**
  #
  # Retrying a write is only safe when the server promises that replaying the
  # same idempotency key returns the original record rather than acting twice.
  # Two resources document that promise (payment_demands and refund_demands,
  # see `idempotent_writes` in contract/manifest.yml); the rest merely carry an
  # `idempotency_key` field, which is not the same thing — meter_ticks says
  # only that the key must be *unique*, a constraint rather than a guarantee.
  #
  # So a write opts in explicitly, per operation, and only once its replay
  # contract has been exercised. Inferring it from the presence of a body key
  # would be guessing with someone's money.
  class RetryPolicy
    # Methods with no side effects, which are safe to repeat by definition.
    SAFE_METHODS = %i[get head options].freeze

    # A server can ask for a longer wait than any request deserves. Beyond
    # this the caller is better served by an error it can queue and retry
    # itself than by a worker blocked for minutes.
    MAX_HONOURED_RETRY_AFTER = 30

    # Errors worth another attempt.
    #
    # A transport failure says nothing about whether the server acted. Neither,
    # strictly, does a 5xx: a 504 usually means the origin *did* receive the
    # request. What makes replaying one of these safe is not the status — it is
    # the server-side idempotency key, which is why only resources with a
    # documented replay contract may opt a write into retries at all.
    #
    # Every other status means the request was seen and judged on its merits,
    # so repeating it cannot help.
    #
    # Public because Transport#dispatch rescues exactly this list. Two lists
    # that must agree about when money may move twice is one list too many.
    RETRYABLE = [ConnectionError, RateLimitError, ServerError].freeze

    attr_reader :max_retries, :base_delay, :max_delay

    def initialize(max_retries:, base_delay:, max_delay:, sleeper: nil, random: Random.new)
      @max_retries = max_retries
      @base_delay = base_delay
      @max_delay = max_delay
      @sleeper = sleeper || ->(seconds) { sleep(seconds) }
      @random = random
    end

    def self.safe_method?(method) = SAFE_METHODS.include?(method.to_s.downcase.to_sym)

    # `retriable` is the caller's explicit statement about this operation, and
    # it can only ever narrow what is allowed: a write marked retriable is
    # still not retried on a status that says the server already acted.
    def retry?(error:, attempt:, retriable:)
      return false unless retriable
      return false if attempt > max_retries

      retryable_error?(error)
    end

    def delay_for(error:, attempt:)
      honoured = retry_after(error)
      return honoured if honoured

      # Exponential backoff with full jitter. Without jitter, every client that
      # failed together retries together, and the recovering server is hit by
      # the same thundering herd that knocked it over.
      ceiling = [base_delay * (2**(attempt - 1)), max_delay].min
      @random.rand * ceiling
    end

    def wait(seconds) = @sleeper.call(seconds)

    private

    def retryable_error?(error) = RETRYABLE.any? { |klass| error.is_a?(klass) }

    # `Retry-After` is either delta-seconds or an HTTP-date (RFC 9110 10.2.3).
    # Clients that handle only the integer form silently ignore the date form
    # and hammer a server that asked them not to.
    def retry_after(error)
      return nil unless error.respond_to?(:headers)

      raw = error.headers.to_h.find { |name, _| name.to_s.downcase == "retry-after" }&.last
      return nil if raw.nil?

      seconds = parse_retry_after(raw.to_s.strip)
      return nil if seconds.nil? || seconds.negative?

      [seconds, MAX_HONOURED_RETRY_AFTER].min
    end

    def parse_retry_after(value)
      return Integer(value, 10) if value.match?(/\A\d+\z/)

      (Time.httpdate(value) - Time.now).ceil
    rescue ArgumentError
      nil
    end
  end
end
