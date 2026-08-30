#!/usr/bin/env ruby
# frozen_string_literal: true

# Derives contract/manifest.yml from the Edge (ept) Phoenix source.
#
# The manifest — not openapi.json — is this client's source of truth for what
# each resource supports. openapi.json describes *responses* only: every write
# operation in it carries `requestBody: null`, so it cannot say which attributes
# or relationships are writable. The Phoenix views can: they declare fields,
# relationship targets, cardinality, and `readonly: true`.
#
# Usage:
#   contract/bin/extract_manifest.rb /path/to/edge/ept > contract/manifest.yml
#
# The generated diff is meant to be read by a human before committing. This
# script parses Elixir with regular expressions; it reports what it could not
# understand rather than guessing.

require "json"
require "yaml"

EPT = ARGV[0] or abort "usage: #{$PROGRAM_NAME} /path/to/edge/ept [openapi.json]"
OPENAPI = ARGV[1] || File.expand_path("../openapi.json", __dir__)

abort "not a directory: #{EPT}" unless File.directory?(EPT)

VIEWS = File.join(EPT, "lib/core_http/views")
CONTROLLERS = File.join(EPT, "lib/core_http/controllers")

# Fields the client must never print in inspect output, exception messages, log
# lines or instrumentation payloads. Keyed by ROUTE NAME (the path segment), not
# by the view's JSON:API type: those diverge for financial_institutions.
#
# This list is maintained by hand and deliberately errs wide. A field appearing
# here is a redaction obligation, not a description of how secret it is. Any
# field named here that a view does not declare raises a warning, so the list
# cannot rot silently against a renamed field.
SENSITIVE = {
  "merchant_tokens" => %w[token],
  "webhook_subscriptions" => %w[secret_key],
  # Edge-issued tokens rather than PAN data, but reusable charge credentials.
  "payment_methods" => %w[card_cvv_token card_pan_token],
  "personal_identifications" => %w[
    dob email full_name id_number name_on_document personal_name phone_number surname
  ],
  "customers" => %w[email name phone_number],
  "consumer_addresses" => %w[line_1 line_2 city state zip],
  "legal_addresses" => %w[line_1 line_2 city state zip],
  "accounts" => %w[email name]
}.freeze

# Redacted wherever they appear, regardless of resource: header names and any
# request-level credential.
SENSITIVE_ALWAYS = %w[authorization api_key secret_key token].freeze

# Resources whose views document a server-side REPLAY contract for
# `idempotency_key`: repeating a request with the same key returns the original
# record instead of acting twice.
#
# Carrying the field is not the same thing and does not belong here.
# payment_subscriptions merely inherits idempotency_view_fields/1 and says
# nothing about replay; meter_ticks says the key "needs to be unique", which is
# a uniqueness constraint, not a replay guarantee. Both stay out, and the
# generator warns about the difference rather than letting it pass unnoticed.
#
# Membership here still does not authorise automatic retries. Each operation
# must be exercised against sandbox first.
IDEMPOTENT = %w[payment_demands refund_demands].freeze

# ---------------------------------------------------------------------------
# Elixir source parsing
# ---------------------------------------------------------------------------

# Returns the contents of the `%{ ... }` map that follows `def <name>(),  do:`,
# balancing braces so nested maps and tuples survive.
def map_body(source, name)
  start = source.index(/def\s+#{Regexp.escape(name)}\(\)\s*,?\s*\n?\s*do:\s*%\{/m)
  return nil unless start

  open = source.index("%{", start) + 2
  depth = 1
  index = open
  while depth.positive? && index < source.length
    case source[index]
    when "{" then depth += 1
    when "}" then depth -= 1
    end
    index += 1
  end
  source[open...(index - 1)]
end

# Splits a map body on commas that sit at nesting depth zero and outside
# strings, so `a: {X, opts: [1, 2]}, b: :c` yields two entries.
def split_entries(body)
  entries = []
  current = +""
  depth = 0
  in_string = false
  escape = false

  body.each_char do |char|
    if escape
      current << char
      escape = false
      next
    end

    case char
    when "\\" then escape = true
    when '"' then in_string = !in_string
    when "{", "[", "(" then depth += 1 unless in_string
    when "}", "]", ")" then depth -= 1 unless in_string
    when ","
      if depth.zero? && !in_string
        entries << current
        current = +""
        next
      end
    end
    current << char
  end
  entries << current
  entries.map(&:strip).reject(&:empty?)
end

def parse_fields(body)
  return {} unless body

  split_entries(body).each_with_object({}) do |entry, fields|
    name, spec = entry.split(":", 2)
    next unless name && spec

    name = name.strip
    next unless name.match?(/\A[a-z_][a-zA-Z0-9_]*\z/)

    spec = spec.strip
    # `:timestamp`
    # `{:string, description: …}`
    # `{{:array, :string}, …}`
    # `{{:array, {:schema, CoreHTTP.Schemas.PaymentLineItem}}, …}`
    array_of = spec.match(
      /\A\{\s*\{\s*:array\s*,\s*(?::(?<atom>[a-z_]+)|\{\s*:schema\s*,\s*(?<schema>[A-Za-z0-9_.]+))/
    )

    type =
      if array_of
        "array[#{array_of[:atom] || array_of[:schema]}]"
      elsif spec.start_with?("{")
        spec[/\A\{\s*:([a-z_]+)/, 1]
      else
        spec[/\A:([a-z_]+)/, 1]
      end

    field = { "type" => type || "unknown" }
    if spec.include?("values:")
      # `values: Mod.fun()` or an inline `values: [:a, :b]`.
      field["enum_source"] = spec[/values:\s*([A-Za-z0-9_.]+\(\))/, 1]
      if (inline = spec[/values:\s*\[([^\]]*)\]/, 1])
        field["values"] = inline.scan(/:([a-z_][a-zA-Z0-9_]*)/).flatten
      end
    end
    # Attributes carry `readonly: true` as well as relationships. This is the
    # one piece of write-side truth the server source does expose.
    field["writable"] = false if spec.include?("readonly: true")
    field["parse_failed"] = true unless type
    fields[name] = field
  end
end

# Maps `Core.Transactions.PaymentDemand` to lib/core/transactions/payment_demand.ex.
def module_path(mod)
  return nil unless mod

  segments = mod.split(".").map { |segment| segment.gsub(/([a-z0-9])([A-Z])/, '\1_\2').downcase }
  File.join(EPT, "lib", "#{segments.join("/")}.ex")
end

# Every Elixir file under lib/core, searched when an enum accessor is not in
# the module it is called on. Built once; the tree is small.
ENUM_SOURCES = Dir.glob(File.join(EPT, "lib/core/**/*.ex")).freeze

# Resolves `Core.Transactions.RefundDemand.reasons()` to the literal list behind
# the `@reasons` module attribute it returns. The openapi snapshot also carries
# enum values, but it lags the server; the schema source does not.
def resolve_enum(reference)
  mod, function = reference.to_s.match(/\A(.+)\.([a-z_][a-zA-Z0-9_]*)\(\)\z/)&.captures
  return nil unless function

  # The accessor usually lives in the module it is named on, but some are
  # injected by a macro in a sibling module (Core.Transactions.Payment defines
  # capture_methods/0 for PaymentDemand).
  #
  # Search order matters for correctness, not just speed. If the module's own
  # file defines the accessor, the attribute MUST come from that same file:
  # accessor names like `types/0` are not unique across the tree, and falling
  # through to a grep would happily bind Core.Banking.ProcessorDetail.types/0
  # to Core.Banking.PayoutDemand's unrelated @types. Only when the module's own
  # file does not define the accessor at all is it safe to look for the macro
  # that injected it.
  own = module_path(mod)
  if own && File.exist?(own) && defines_accessor?(File.read(own), function)
    return enum_values(File.read(own), function)
  end

  # No unambiguous owner: collect every definer rather than taking the first.
  # Accessor names are not unique across the tree — two modules define
  # billing_periods/0 — and picking alphabetically would bind
  # Core.Transactions.PaymentSubscription.billing_periods/0 to
  # Core.Purchases.Link's list. Their values agree today, which is exactly why
  # a first-match rule would look correct right up until it wasn't.
  candidates = ENUM_SOURCES.filter_map do |path|
    source = File.read(path)
    next unless defines_accessor?(source, function)

    values = enum_values(source, function)
    [path, values] if values
  end

  return nil if candidates.empty?

  distinct = candidates.map(&:last).uniq
  return nil if distinct.size > 1 || candidates.size > 1

  candidates.first.last
end

# Reports accessors that more than one module defines, so an ambiguous
# resolution is visible in the warnings rather than silently resolved.
def enum_ambiguity(reference)
  mod, function = reference.to_s.match(/\A(.+)\.([a-z_][a-zA-Z0-9_]*)\(\)\z/)&.captures
  return nil unless function

  own = module_path(mod)
  return nil if own && File.exist?(own) && defines_accessor?(File.read(own), function)

  definers = ENUM_SOURCES.select { |path| defines_accessor?(File.read(path), function) }
  return nil if definers.size < 2

  # Sorted because this list is interpolated into a warning that is written
  # into the committed manifest. Dir.glob has sorted by default since Ruby 3.0,
  # but the manifest's stability should not rest on that: sorting here means
  # the output is identical no matter how the file list was produced.
  definers.map { |path| path.sub("#{EPT}/", "") }.sort
end

def defines_accessor?(source, function)
  source.match?(/def\s+#{Regexp.escape(function)}\(\)\s*,\s*do:\s*@[a-z_]/)
end

# Reads the module attribute the accessor returns. Handles a literal list
# (`@reasons [:a, :b]`) and a literal map whose keys are the enum values
# (`@types %{estimated: …}`, surfaced by the schema as `Map.keys(@types)`).
# Anything computed (`@violations @a ++ @b`) is deliberately unresolvable:
# returning nil sends the caller to the snapshot with a marker, which is
# honest, where guessing would not be.
def enum_values(source, function)
  attribute = source[/def\s+#{Regexp.escape(function)}\(\)\s*,\s*do:\s*@([a-z_][a-zA-Z0-9_]*)/, 1]
  return nil unless attribute

  if (list = source[/^\s*@#{Regexp.escape(attribute)}\s+\[(.*?)\]/m, 1])
    # A plain list of atoms, `[:a, :b]`.
    values = list.scan(/:([a-z_][a-zA-Z0-9_]*)/).flatten
    return values unless values.empty?

    # A keyword list, `[edge: "Edge", legit_script: "LegitScript"]`, whose keys
    # are the enum values. Same key-value shape as the map form below.
    values = split_entries(list).filter_map { |entry| entry[/\A([a-z_][a-zA-Z0-9_]*):/, 1] }
    return values unless values.empty?
  end

  if (map = map_body_after(source[/^\s*@#{Regexp.escape(attribute)}\s+%\{.*/m].to_s, "%{"))
    values = split_entries(map).filter_map { |entry| entry[/\A([a-z_][a-zA-Z0-9_]*):/, 1] }
    return values unless values.empty?
  end

  nil
end

# `fields()` bodies are often a literal map piped through `*_view_fields/1`
# helpers that Map.merge further attributes in. Follow those pipes.
def resolve_field_helpers(source, warnings, filename)
  # Stop at the next top-level definition, or at end of module when fields/0 is
  # the last one. `defp` must terminate too: scanning past it into a private
  # helper would merge unrelated `|> Mod.fun()` pipes as if they were fields.
  pipeline = source[/def\s+fields\(\).*?(?=\n\s*(?:defp?|@[a-z_]+)\s|\nend\s*\z)/m]
  unless pipeline
    warnings << "#{filename}: could not delimit fields/0; helper pipes not followed"
    return {}
  end

  pipes = pipeline.scan(/\|>\s*([A-Za-z0-9_.]+)\.([a-z_]+)\(\)/)
  pipes.each_with_object({}) do |(mod, function), merged|
    path = module_path(mod)
    unless path && File.exist?(path)
      warnings << "#{filename}: cannot resolve #{mod}.#{function}/1"
      next
    end

    helper = File.read(path)[/def\s+#{Regexp.escape(function)}\(fields\)\s*do\b.*?\n  end/m]
    unless helper
      warnings << "#{filename}: cannot read #{mod}.#{function}/1"
      next
    end

    merged.merge!(parse_fields(map_body_after(helper, "Map.merge")))
  end
end

# Balanced read of the `%{ ... }` that follows a marker such as `Map.merge`.
def map_body_after(source, marker)
  start = source.index(marker)
  return nil unless start

  open = source.index("%{", start)
  return nil unless open

  open += 2
  depth = 1
  index = open
  while depth.positive? && index < source.length
    case source[index]
    when "{" then depth += 1
    when "}" then depth -= 1
    end
    index += 1
  end
  source[open...(index - 1)]
end

def parse_relationships(body)
  return {} unless body

  split_entries(body).each_with_object({}) do |entry, rels|
    name, spec = entry.split(":", 2)
    next unless name && spec

    name = name.strip
    next unless name.match?(/\A[a-z_][a-zA-Z0-9_]*\z/)

    spec = spec.strip
    view = spec[/CoreHTTP\.Views\.([A-Za-z0-9_]+)/, 1]
    next unless view

    rels[name] = {
      "view" => view,
      "cardinality" => spec.include?("has: :many") ? "many" : "one",
      "writable" => !spec.include?("readonly: true")
    }
  end
end

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

openapi = JSON.parse(File.read(OPENAPI))

# type => { path_version, operations, custom_actions } straight from the spec's paths.
routes = Hash.new { |hash, key| hash[key] = { "operations" => [], "custom_actions" => [] } }
openapi.fetch("paths").each do |path, verbs|
  match = path.match(%r{\A/(v\d+)/([a-z_]+)})
  next unless match

  version = match[1]
  type = match[2]
  entry = routes[type]
  entry["api_version"] = version

  verbs.each_key do |verb|
    next unless %w[get post patch put delete].include?(verb)

    tail = path.sub(%r{\A/v\d+/[a-z_]+}, "")
    case [verb, tail]
    in ["get", ""] then entry["operations"] << "list"
    in ["get", "/{id}"] then entry["operations"] << "retrieve"
    in ["post", ""] then entry["operations"] << "create"
    in ["patch", "/{id}"] then entry["operations"] << "update"
    in ["delete", "/{id}"] then entry["operations"] << "delete"
    else
      if tail.match?(%r{\A/\{id\}/(?!relationships/)})
        entry["custom_actions"] << { "verb" => verb.upcase,
                                     "path" => tail }
      end
    end
  end
end

# Enum values, taken from the response snapshot. Flagged, because the snapshot
# is a build artifact that lags the server (see contract/PROVENANCE.md).
enums = {}
openapi_attributes = {}
openapi.fetch("components").fetch("schemas").each do |name, schema|
  next unless name.end_with?("_member")

  type = name.sub(/_member\z/, "")
  attributes = schema.dig("properties", "data", "properties", "attributes", "properties") || {}
  openapi_attributes[type] = attributes
  attributes.each do |field, spec|
    enums[[type, field]] = spec["enum"] if spec["enum"]
  end
end

warnings = []
resources = {}

Dir.children(VIEWS).sort.each do |filename|
  next unless filename.end_with?(".ex")

  source = File.read(File.join(VIEWS, filename))
  type = source[/def\s+type\(\)\s*,\s*do:\s*"([a-z_]+)"/, 1]
  unless type
    warnings << "#{filename}: could not read type/0"
    next
  end

  # The view's type/0 is what the server puts in `data.type`. The route segment
  # is what a client asks for. They are normally identical; where they are not,
  # a type -> class registry would mis-instantiate the response, and the spec
  # generator emits no schema of its own for the shadowed resource.
  route_name = filename.sub(/\.ex\z/, "")
  if type != route_name
    warnings << "#{filename}: view type/0 is #{type.inspect} but the route is /#{route_name} " \
                "- responses from that route are mistyped"
  end
  if (claimed = resources.find { |_, spec| spec["json_api_type"] == type })
    warnings << "#{filename}: JSON:API type #{type.inspect} is already claimed by #{claimed[0]}"
  end

  fields_body = map_body(source, "fields")
  fields = parse_fields(fields_body).merge(resolve_field_helpers(source, warnings, filename))
  relationships = parse_relationships(map_body(source, "relationships"))

  if fields.empty? && !fields_body.to_s.strip.empty?
    warnings << "#{filename}: fields/0 is non-empty but nothing parsed"
  end

  fields.each do |name, spec|
    warnings << "#{filename}: could not parse field #{name}" if spec.delete("parse_failed")
    spec["from"] = "view"

    # Schema names in the snapshot derive from the view's type/0, not the route.
    snapshot = enums[[type, name]]
    live = spec["values"] || resolve_enum(spec["enum_source"])

    if (ambiguous = enum_ambiguity(spec["enum_source"]))
      warnings << "#{filename}: #{name} accessor #{spec["enum_source"]} is defined in " \
                  "#{ambiguous.join(" and ")}; not resolving from source"
    end

    if live
      spec["values"] = live
      if snapshot && snapshot.sort != live.sort
        spec["snapshot_values"] = snapshot
        spec["snapshot_stale"] = true
      end
    elsif snapshot
      spec["values"] = snapshot
      spec["values_from"] = "openapi-snapshot"
      if spec["type"] == "enum"
        warnings << "#{filename}: enum #{name} resolved from the snapshot only"
      end
    elsif spec["type"] == "enum"
      warnings << "#{filename}: enum #{name} has no resolvable values"
    end
  end

  # Attributes the snapshot documents but the view no longer declares, and vice
  # versa. Both directions matter: the first may be a removal the client should
  # stop relying on, the second a field newer than the snapshot.
  documented = (openapi_attributes[type] || {}).keys
  (documented - fields.keys).each do |name|
    fields[name] = { "type" => "unknown", "from" => "openapi-snapshot-only" }
    warnings << "#{filename}: #{name} is in the snapshot but not in the view"
  end

  route = routes[route_name]
  controller = File.join(CONTROLLERS, "#{route_name}_controller.ex")
  controller = nil unless File.exist?(controller)

  sensitive = (SENSITIVE[route_name] || []) & fields.keys
  missing = (SENSITIVE[route_name] || []) - fields.keys
  unless missing.empty?
    warnings << "#{filename}: sensitive fields not present: #{missing.join(", ")}"
  end

  # The idempotency list is hand-maintained; the field's presence is not. Flag
  # any drift between them in both directions.
  declares_key = fields.key?("idempotency_key")
  if declares_key && !IDEMPOTENT.include?(route_name)
    warnings << "#{filename}: declares idempotency_key but documents no replay contract; " \
                "writes stay non-retryable"
  elsif !declares_key && IDEMPOTENT.include?(route_name)
    warnings << "#{filename}: is in IDEMPOTENT but declares no idempotency_key"
  end

  resources[route_name] = {
    "json_api_type" => type,
    "api_version" => route["api_version"] || "unknown",
    "source" => source[/def\s+source\(\)\s*,\s*do:\s*([A-Za-z0-9_.]+)/, 1],
    "controller" => controller ? File.basename(controller) : nil,
    "operations" => route["operations"].uniq.sort,
    "custom_actions" => route["custom_actions"],
    "idempotent_writes" => IDEMPOTENT.include?(route_name),
    "sensitive_fields" => sensitive,
    "attributes" => fields,
    "relationships" => relationships
  }.compact
end

missing_views = routes.keys - resources.keys
warnings << "routed but no view found: #{missing_views.join(", ")}" unless missing_views.empty?

manifest = {
  "generated_by" => "contract/bin/extract_manifest.rb",
  "generated_from" => "Phoenix views and controllers; routes, and enum values that could not be " \
                      "resolved from source, come from contract/openapi.json",
  "caveats" => [
    "openapi.json describes responses only. Every write has requestBody: null, so writable " \
    "ATTRIBUTES are not derivable and are not asserted here. Relationship writeability IS " \
    "derivable, from `readonly: true` in each view.",
    "Enum values come from the openapi.json snapshot, which is a gitignored build artifact " \
    "that lags the server. Treat them as a lower bound: the client must accept unknown values.",
    "sensitive_fields is hand-maintained in this script and errs wide. It is a redaction " \
    "obligation, not a claim about how secret a field is.",
    "idempotent_writes marks resources whose views document a replay contract. It does NOT " \
    "authorise automatic retries; each operation must be exercised against sandbox first."
  ],
  "warnings" => warnings,
  "always_redact" => SENSITIVE_ALWAYS,
  "resources" => resources
}

puts manifest.to_yaml
warn "#{resources.size} resources, #{warnings.size} warnings"
warnings.each { |warning| warn "  ! #{warning}" }
