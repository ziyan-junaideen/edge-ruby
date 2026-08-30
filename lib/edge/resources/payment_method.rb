# frozen_string_literal: true

module Edge
  # A stored card: `/v2/payment_methods`.
  #
  # **Read-only, and not by choice of this client.** `/v2/payment_methods` is
  # mounted `only: [:index, :show]` (`core_web/router.ex:270-274`); there is no
  # create, update or delete route anywhere in the API. `Edge::PaymentMethod`
  # therefore has no `.create` at all, rather than one that would return a 404
  # and read as a server fault.
  #
  # A payment method is created by the browser — the Edge iFrame and Edge.js,
  # with a publishable key — so that card data never reaches a merchant's
  # server, and this gem refuses a publishable key for exactly that reason
  # (see Edge::ApiKey). A payment demand then references the stored method by
  # id; it never carries a card number.
  #
  # `card_pan_token` and `card_cvv_token` are the vault's handles for the card.
  # They are not the card number, but they authorise charges, so they are
  # treated as secrets everywhere except `#raw`.
  class PaymentMethod < Resource
    contract "payment_methods"

    # "4242" — safe to show a cardholder, and the only part of the number the
    # API returns.
    def last_four = self[:last_four]

    def discarded? = !self[:discarded_at].nil?

    # `expiry_month`/`expiry_year` as the server sent them. Deliberately not
    # turned into a Date: the API's own values are unvalidated strings, and a
    # reader that raised on a malformed one would fail at display time.
    #
    # **Returns `[nil, nil]` against today's API.** The view declares both
    # fields, but the schema stores a single `card_expiry` date and neither
    # declaration carries a `from:` mapping, so the serializer drops them and
    # no payment method has ever carried either — verified against a running
    # instance. See docs/release-blockers.md, FU-14.
    #
    # Kept rather than removed because the fix upstream is a one-line `from:`,
    # after which this reader works unchanged. `#expiry_known?` is how a caller
    # asks whether there is anything to show.
    def expiry = [self[:expiry_month], self[:expiry_year]]

    # False whenever the API omitted the expiry, which is currently always.
    # A caller prompting a cardholder about a lapsing card needs to tell "not
    # sent" from "expires in month nil".
    def expiry_known? = expiry.none?(&:nil?)
  end
end
