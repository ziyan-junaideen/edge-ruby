# frozen_string_literal: true

module Edge
  # Emits one `edge.request` event per HTTP request.
  #
  # The payload carries **safe metadata only**: method, a path template with
  # identifiers removed, status, duration, retry count and request id. Never
  # the API key, never a request or response body, never a query string — a
  # filter value can be a customer's email address, and these payloads are
  # exactly what gets forwarded to APM vendors and log aggregators.
  #
  # Uses ActiveSupport::Notifications when it is loaded, so Rails applications
  # get subscriptions for free, and is a no-op otherwise. The core gem does not
  # depend on ActiveSupport.
  module Instrumentation
    EVENT = "edge.request"

    # Identifiers are replaced so that events group by endpoint rather than
    # fragmenting into one series per record.
    UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

    class << self
      # Yields, then emits. Returns whatever the block returns; an exception
      # propagates after the event is emitted with its error class recorded.
      def instrument(instrumenter, method:, url:, retries: 0)
        started = monotonic
        payload = { method: method.to_s.upcase, path: path_template(url), retries: retries }

        record_success(payload, yield)
      rescue Exception => e # rubocop:disable Lint/RescueException
        # Exception, not StandardError: an Interrupt or SIGTERM part-way
        # through a payment must not emit an event that a subscriber reads as a
        # clean request. The exception is re-raised untouched.
        record_failure(payload, e)
        raise
      ensure
        payload[:duration] = monotonic - started
        emit(instrumenter, payload)
      end

      # `/v2/payment_demands/78f3ce12-.../confirm` -> `/v2/payment_demands/:id/confirm`
      def path_template(url)
        path = URI.parse(url.to_s).path.to_s
        return path if path.empty?

        path.split("/", -1).map { |segment| identifier?(segment) ? ":id" : segment }.join("/")
      rescue URI::Error
        "(unparseable)"
      end

      # The API's own path vocabulary, from the contract. An earlier version
      # guessed with a length heuristic and quietly rewrote
      # `/v2/personal_identifications` to `/v2/:id`, merging exactly the
      # endpoints the template exists to keep apart.
      #
      # Falls back to recognising UUIDs only if the contract cannot be read:
      # better to under-template than to mangle real endpoint names.
      def known_segments
        @known_segments ||= Contract.path_segments
      rescue StandardError
        @known_segments = [].freeze
      end

      private

      def record_success(payload, response)
        payload[:status] = response.status if response.respond_to?(:status)
        payload[:request_id] = request_id(response)
        response
      end

      def record_failure(payload, error)
        payload[:error] = error.class.name
        payload[:status] = error.status if error.respond_to?(:status)
        # Also on the failure path. A request id is most useful precisely when
        # something went wrong and the server's own logs need correlating.
        payload[:request_id] = error.request_id if error.respond_to?(:request_id)
      end

      def identifier?(segment)
        return false if segment.empty?
        return true if segment.match?(UUID)

        known_segments.any? && !known_segments.include?(segment)
      end

      def request_id(response)
        return nil unless response.respond_to?(:headers)

        response.headers.to_h.find { |name, _| name.to_s.downcase == "x-request-id" }&.last
      end

      def emit(instrumenter, payload)
        instrumenter ||= default_instrumenter
        return if instrumenter.nil?

        # Emitted around an already-completed block: subscribers should not be
        # able to change the outcome, and an instrumentation failure must not
        # turn a successful request into an exception.
        instrumenter.instrument(EVENT, payload) { nil }
      rescue StandardError
        nil
      end

      def default_instrumenter
        return nil unless defined?(ActiveSupport::Notifications)

        ActiveSupport::Notifications
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
