# frozen_string_literal: true

require_relative "lib/edge/version"

Gem::Specification.new do |spec|
  spec.name = "edge-ruby"
  spec.version = Edge::VERSION
  spec.authors = ["Ziyan Junaideen"]
  spec.email = ["zjunaideen@gmail.com"]

  spec.summary = "Unofficial Ruby client for the Edge Payment Technologies API"
  spec.description = <<~DESCRIPTION
    An unofficial Ruby client for the Edge Payment Technologies JSON:API, for
    Rails, Sinatra and plain Rack applications. Not published, supported or
    certified by Edge Payment Technologies.
  DESCRIPTION

  spec.homepage = "https://github.com/ziyan-junaideen/edge-ruby"
  spec.license = "MIT"

  # Bounded to the minors the CI matrix actually runs: 3.2, 3.3, 3.4, 4.0.
  # Ruby 3.4 was followed by 4.0, so there is no 3.5 line to include.
  #
  # `< 5` would promise 4.1 through 4.9 as well, none of which exist yet and
  # none of which could be tested. Widening this without adding the Ruby to
  # .github/workflows/ci.yml fails spec/edge/packaging_spec.rb, and so does the
  # reverse.
  spec.required_ruby_version = Gem::Requirement.new(">= 3.2", "< 4.1")

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "rubygems_mfa_required" => "true"
  }

  # Globbed relative to this file, not the process working directory. `Dir[]`
  # against cwd silently yields [] when the gemspec is loaded from anywhere
  # else, which produces a gem that ships nothing and still validates.
  spec.files = Dir.chdir(__dir__) do
    Dir[
      "lib/**/*.rb",
      "contract/manifest.yml",
      "CHANGELOG.md",
      "LICENSE",
      "README.md",
      "SECURITY.md"
    ]
  end
  spec.require_paths = ["lib"]

  # Bounded to the supported major so a future breaking Faraday release is not
  # pulled into an application automatically.
  spec.add_dependency "faraday", ">= 2.0", "< 3"
end
