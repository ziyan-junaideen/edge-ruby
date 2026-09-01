# frozen_string_literal: true

module Edge
  # One attempt to deliver an event: `/v2/webhook_deliveries`.
  #
  # Read-only, and useful mainly for answering "did that event reach us?"
  # after the fact. `fails_count` is what makes a redelivery visible from the
  # outside, and a redelivery carries a signature that verifies exactly like
  # the first — which is why a consumer deduplicates on the event id.
  #
  # **`GET /v2/webhook_deliveries` answers 500 today** (FU-22).
  class WebhookDelivery < Resource
    contract "webhook_deliveries"

    # True when at least one attempt has failed.
    #
    # Deliberately not called `retried?`. `fails_count` is incremented on
    # every failure (`webhook_delivery.ex:69`), but a 400, 401, 403, 404 or
    # 405 is not retried at all (`deliver_webhook_job.ex:139`) — so a delivery
    # your endpoint 404'd has a count of one and was never retried. It also
    # does not mean "undelivered": one that failed twice and then succeeded
    # still reports two.
    def failed_attempt? = failed_attempts.positive?

    # How many attempts have failed. Zero when the server sent no count.
    def failed_attempts = self[:fails_count].to_i
  end
end
