# frozen_string_literal: true

# Checks the manifest against a running Edge instance.
#
# Excluded from the default run: it needs a server and a credential, and the
# rest of the suite is forbidden from touching the network. Enable it with
#
#   EDGE_LIVE_URL=https://api.tryedge.test:4001 \
#   EDGE_LIVE_KEY=ept_sandbox_s... \
#   EDGE_LIVE_CA=/path/to/rootCA.pem \
#     bundle exec rspec spec/contract/live_spec.rb --tag live
#
# `EDGE_LIVE_CA` is optional; `EDGE_LIVE_INSECURE=1` skips verification, which
# the client permits only for a .test/.local/loopback host.
#
# Read-only on purpose. The write half of the lifecycle is not repeatable — a
# refund moves its payment demand to `refunded` and no second refund is
# possible against it — so what a spike proved once by hand is recorded in
# docs/release-blockers.md rather than pretended to be a test.
RSpec.describe "the live API", :live do
  def client
    @client ||= Edge::Client.new(
      api_key: ENV.fetch("EDGE_LIVE_KEY"),
      base_url: ENV.fetch("EDGE_LIVE_URL"),
      ssl: ssl_options
    )
  end

  def ssl_options
    return { ca_file: ENV["EDGE_LIVE_CA"] } if ENV["EDGE_LIVE_CA"]
    return { verify: false } if ENV["EDGE_LIVE_INSECURE"]

    nil
  end

  # Resources this credential may read. A token scoped to one merchant gets a
  # 403 on the platform-wide ones, and that is a fact about the token rather
  # than a disagreement about the contract.
  def readable
    @readable ||= Edge::Contract.resources.filter_map do |name, spec|
      next unless spec["operations"].include?("list")

      body = client.get("#{spec["api_version"]}/#{name}").data
      record = Array(body["data"]).first
      [name, spec, record] if record
    rescue Edge::PermissionError, Edge::AuthenticationError
      nil
    end
  end

  it "actually reached a useful number of resources" do
    # Three of the examples below asserted that a difference is empty, and an
    # empty `readable` satisfies all of them without checking anything. A
    # credential with no permissions, or a server with an empty database,
    # would otherwise report a clean contract.
    expect(readable.map(&:first)).to include("customers", "payment_demands", "payment_methods")
    expect(readable.size).to be >= 8
  end

  it "answers with the JSON:API version the client is written against" do
    body = client.get("v2/customers").data

    expect(body.dig("jsonapi", "version")).to eq("1.1")
  end

  it "serializes the type each resource records, for every readable resource" do
    mismatched = readable.filter_map do |name, spec, record|
      [name, spec["json_api_type"], record["type"]] if record["type"] != spec["json_api_type"]
    end

    expect(mismatched).to be_empty
  end

  it "sends no attribute the manifest has not recorded" do
    # The direction that matters for a client: an attribute the server sends
    # and the manifest lacks is a reader the caller cannot reach, and a sign
    # the manifest needs regenerating.
    undeclared = readable.filter_map do |name, spec, record|
      extra = record["attributes"].keys - (spec["attributes"] || {}).keys
      [name, extra] if extra.any?
    end

    expect(undeclared).to be_empty
  end

  it "sends no relationship the manifest has not recorded" do
    undeclared = readable.filter_map do |name, spec, record|
      extra = (record["relationships"] || {}).keys - (spec["relationships"] || {}).keys
      [name, extra] if extra.any?
    end

    expect(undeclared).to be_empty
  end

  # The other direction, which is a documentation problem rather than a client
  # one. Pinned as an exact set so that a field starting or stopping being
  # serialized shows up here instead of going unnoticed. See
  # docs/release-blockers.md, FU-14 and FU-15.
  it "still omits exactly the attributes known to be declared and never sent" do
    known_absent = {
      "beneficial_owners" => %w[icon_url login_url logo_url name primary_colour state],
      "merchant_tokens" => %w[expiry],
      "merchants" => %w[business_privacy_policy_url],
      "payment_demands" => %w[amount_refunded_cents confirmed],
      "payment_methods" => %w[expiry_month expiry_year],
      "payment_subscriptions" => %w[confirmed]
    }

    # Keyed on what was actually read, not on what is currently missing. Doing
    # the latter drops a resource from both sides the moment every one of its
    # fields starts being sent, so the complete fix — the outcome this example
    # exists to notice — would have passed silently.
    absent = readable.to_h do |name, spec, record|
      [name, ((spec["attributes"] || {}).keys - record["attributes"].keys).sort]
    end
    expected = readable.to_h { |name, _, _| [name, (known_absent[name] || []).sort] }

    expect(absent).to eq(expected)
  end

  it "reports pagination in a shape the client can read, or not at all" do
    # Production does not paginate; the `edg-1498` branch adds
    # `meta.pagination` (docs/pagination.md). Both are legitimate answers
    # depending on which the instance runs, so this pins the shape rather than
    # the presence — asserting `limit` exists would fail against production,
    # and asserting it does not would fail against the branch.
    meta = client.get("v2/customers").data.dig("meta", "pagination")

    expect(meta).to be_nil.or include("limit")
    expect(meta["limit"]).to be_a(Integer) if meta
  end

  describe "a to-many relationship" do
    it "carries a link and no linkage, whatever include: asked for" do
      # FU-11. Edge::Relationship reports these as unloaded, and this is the
      # check that the reason it does so still holds.
      customer = client.get("v2/customers", params: { "include" => "addresses" })
                       .data["data"].first
      addresses = customer["relationships"]["addresses"]

      expect(addresses).to have_key("links")
      expect(addresses).not_to have_key("data")
    end
  end
end
