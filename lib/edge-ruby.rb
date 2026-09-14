# frozen_string_literal: true

# Bundler requires the file matching the gem name, so `gem "edge-ruby"` looks
# for "edge-ruby" rather than "edge". This shim means callers do not need
# `require: "edge"` in their Gemfile.
require_relative "edge"
