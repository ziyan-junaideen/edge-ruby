# frozen_string_literal: true

require_relative "edge/version"

# An unofficial Ruby client for the Edge Payment Technologies HTTP API.
#
# Not published, supported or certified by Edge Payment Technologies. See
# README.md for what the API can and cannot do, and docs/release-blockers.md
# for the gaps that constrain this client's surface.
module Edge
  # Base class for every error this library raises, so callers can rescue the
  # whole library with one constant.
  class Error < StandardError; end
end
