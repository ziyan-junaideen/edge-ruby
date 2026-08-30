# frozen_string_literal: true

module Edge
  # A page of resources, plus whatever it takes to walk to the next one.
  #
  # Two things to know before using it.
  #
  # **Production does not paginate.** The cursor implementation is unmerged, so
  # today a list request returns every matching record in one response and
  # `links.next` is absent. `#auto_paging_each` therefore does one pass over one
  # page — correct either way, but a large merchant's collection arrives whole,
  # in memory. Filter. See docs/pagination.md.
  #
  # **A pagination link is data from the network.** It is a URL the server
  # chooses and this client would attach a bearer token to. So every link is
  # checked against the configured origin before it is followed, and a
  # cross-origin one raises rather than leaking the credential to whatever host
  # the response named.
  class ListObject
    include Enumerable

    attr_reader :document, :client, :resource_class, :max_auto_pages

    # `max_auto_pages` defaults to the client's own setting rather than to a
    # constant here. A second copy of the limit was exactly that: a constant in
    # this file that `Configuration#max_auto_pages` never reached, so the
    # documented setting did nothing.
    def initialize(document:, client:, resource_class: Resource, max_auto_pages: nil)
      @document = document
      @client = client
      @resource_class = resource_class
      @max_auto_pages = validated_limit(max_auto_pages || client.config.max_auto_pages)
    end

    # The records on this page. Never makes a request.
    def each(&) = data.each(&)

    # Built with the client, so a relationship on a record from a list can be
    # fetched without the caller having to supply one again.
    def data = @data ||= resource_class.list_from(document, client: client)

    def length = data.length
    alias size length

    def empty? = data.empty?

    def [](index) = data[index]

    def links = document.links

    def meta = document.meta

    # The URL of the next page, already resolved and origin-checked, or nil
    # when there is none. Raises for a link that must not be followed — asking
    # whether there is a next page is answered honestly, not with a shrug.
    def next_page_url = safe_link("next")

    def next_page? = !next_page_url.nil?

    # The next page, or nil. One request.
    def next_page
      url = next_page_url
      return nil unless url

      page_at(url)
    end

    # Yields every record across every page.
    #
    #   Edge::PaymentDemand.list(filter: { ... }).auto_paging_each { |d| ... }
    #
    # `break` from the block stops immediately, without fetching another page.
    #
    # Note that `#each`, and so `#to_a` and every other Enumerable method,
    # covers **this page only**. That is not a distinction production draws
    # today, since it sends everything in one response, but it will be when the
    # cursor work lands.
    def auto_paging_each(&block)
      return enum_for(:auto_paging_each) unless block_given?

      page = self
      seen = visited_set
      pages = 0

      loop do
        page.each(&block)
        pages += 1
        page = advance(page, seen, pages) or break
      end

      self
    end

    # Every record across every page, as an Array. Named for what it costs.
    def to_a_across_pages = auto_paging_each.to_a

    # Total, unlike `#next_page?`. A malformed or cross-origin `next` link is
    # exactly when someone is inspecting this object, and an `inspect` that
    # raises while an error reporter formats it turns a diagnosable problem
    # into a baffling one. So this reports whether a link is *present*, which
    # needs no network judgement, rather than whether it may be followed.
    def inspect
      "#<#{self.class.name} #{resource_class.name} count=#{length} " \
        "next_link=#{!document.link("next").nil?}>"
    end
    alias to_s inspect

    private

    def page_at(url)
      self.class.new(document: JSONAPI::Document.from_response(client.get(url)),
                     client: client, resource_class: resource_class,
                     max_auto_pages: max_auto_pages)
    end

    def advance(page, seen, pages)
      # Raises for a link that cannot be followed, before anything else.
      url = page.next_page_url
      return nil if url.nil?

      reject_page_limit!(pages)
      reject_cycle!(seen, url)

      page.next_page
    end

    # Every URL already visited, not merely the previous one: a server
    # answering A -> B -> A would otherwise loop until the process died.
    #
    # Seeded with this page's own `self` link where there is a usable one. That
    # link has not been through `safe_link`, so it is the one place a URL may
    # fail to resolve without being an error — we are recording where we have
    # been, not deciding where to go.
    def visited_set
      start = client.url_for(document.link("self")) if document.link("self")
      start ? Set[start] : Set.new
    rescue Error, URI::Error
      Set.new
    end

    # A repeated cursor raises rather than ending the walk quietly. Truncating
    # would hand back a partial collection that looks exactly like a complete
    # one, and a caller cannot tell the difference — which is worse than an
    # error, because the records that went missing were never asked about.
    def reject_cycle!(seen, url)
      return if seen.add?(url)

      raise Error,
            "the API's pagination links loop: #{Redaction.scrub_query(url)} was offered again. " \
            "Stopping, because continuing would repeat records forever and returning what has " \
            "been read so far would look like a complete collection."
    end

    def reject_page_limit!(pages)
      return if pages < max_auto_pages

      raise Error,
            "stopped after #{pages} pages and the API was still offering more. This is a " \
            "safety limit, not a contract — raise max_auto_pages if the collection really is " \
            "this large."
    end

    # A link is checked before it is followed, never after. The bearer token
    # authorises money movement, and this URL came off the wire.
    #
    # The check is `Client#url_for` and nothing else, deliberately: it already
    # raises InsecureRedirectError for an absolute URL off the configured
    # origin, and resolves a relative one against the base, which cannot leave
    # it. A second origin test here would be a second place for the rule to
    # live, and two copies of a security rule eventually disagree.
    def safe_link(name)
      url = document.link(name)
      return nil if url.nil?

      client.url_for(url)
    end

    def validated_limit(limit)
      return limit if limit.is_a?(Integer) && limit.positive?

      raise ArgumentError, "max_auto_pages must be a positive Integer, got #{limit.inspect}"
    end
  end
end
