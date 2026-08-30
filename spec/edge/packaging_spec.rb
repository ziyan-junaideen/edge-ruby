# frozen_string_literal: true

require "open3"
require "tmpdir"

# A gem that passes its unit tests but cannot be built, installed and required
# is not shippable. These run against the real gemspec and, once per suite,
# against a real `gem build` / `gem install`.
RSpec.describe "packaging" do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:gemspec) { Gem::Specification.load(File.join(root, "edge-ruby.gemspec")) }

  describe "the gemspec" do
    it "is valid" do
      expect { gemspec.validate }.not_to raise_error
    end

    it "ships the entrypoint and the bundler shim" do
      expect(gemspec.files).to include("lib/edge.rb", "lib/edge-ruby.rb")
    end

    it "ships the contract manifest the client is built against" do
      expect(gemspec.files).to include("contract/manifest.yml")
    end

    it "does not ship the OpenAPI snapshot" do
      # 600 KB of untrusted, provenance-caveated JSON that no runtime code
      # reads. It belongs in the repository, not in every install.
      expect(gemspec.files).not_to include("contract/openapi.json")
    end

    it "names every file it ships" do
      # The emptiness check is the point: `Dir[]` globs the process working
      # directory, so a gemspec that globs carelessly ships nothing and this
      # example would otherwise pass having verified nothing at all.
      expect(gemspec.files).not_to be_empty

      missing = gemspec.files.reject { |file| File.exist?(File.join(root, file)) }
      expect(missing).to be_empty
    end

    it "ships the same files no matter where it is loaded from" do
      elsewhere = Dir.chdir("/") { Gem::Specification.load(File.join(root, "edge-ruby.gemspec")).files }
      expect(elsewhere).to eq(gemspec.files)
    end

    it "bounds faraday to the supported major" do
      faraday = gemspec.dependencies.find { |dep| dep.name == "faraday" }
      expect(faraday.requirement.to_s).to eq(">= 2.0, < 3")
    end

    it "promises exactly the Ruby minors the CI matrix tests" do
      workflow = YAML.load_file(File.join(root, ".github/workflows/ci.yml"))
      tested = workflow.dig("jobs", "spec", "strategy", "matrix", "ruby").map(&:to_s).sort

      # Both directions matter, and checking only that each tested version is
      # allowed is the weaker half: it cannot see a version the gemspec
      # promises that nobody runs.
      #
      # Compared against the minors that actually exist, not every arithmetic
      # possibility: the 3.x line ended at 3.4 and was followed by 4.0, so
      # 3.5 through 3.9 were never released and promising them is meaningless.
      # Add to this list when a new Ruby minor ships, together with the
      # matrix entry and the gemspec bound.
      released = %w[3.0 3.1 3.2 3.3 3.4 4.0]
      promised = released.select do |version|
        gemspec.required_ruby_version.satisfied_by?(Gem::Version.new(version))
      end

      expect(tested).not_to be_empty
      expect(promised).to eq(tested),
                          "gemspec promises #{promised.inspect} but CI tests #{tested.inspect}"
    end
  end

  describe "a built and installed gem", :packaging do
    # Slow, so it is tagged and can be excluded locally with
    # `rspec --tag '~packaging'`. CI always runs it.
    it "installs and requires under the gem name" do
      Dir.mktmpdir do |dir|
        build = run("gem build edge-ruby.gemspec --output #{dir}/edge-ruby.gem", chdir: root)
        expect(build.last).to be_success, "gem build failed: #{build.first}"

        install = run("gem install --install-dir #{dir}/install --no-document " \
                      "#{dir}/edge-ruby.gem")
        expect(install.last).to be_success, "gem install failed: #{install.first}"

        stdout, stderr, status = run3(
          "ruby -e 'require \"edge-ruby\"; print Edge::VERSION'",
          env: { "GEM_HOME" => "#{dir}/install", "GEM_PATH" => "#{dir}/install" }
        )
        expect(status).to be_success, "require failed: #{stderr}"
        # stdout alone, so a deprecation warning on stderr does not fail this.
        expect(stdout).to eq(Edge::VERSION)
      end
    end
  end

  # Runs outside Bundler. Without this the child process inherits
  # BUNDLE_GEMFILE and RUBYOPT and tries to resolve this repository's
  # development bundle, so the installed gem is never what gets exercised.
  def run(command, chdir: Dir.pwd, env: {})
    Bundler.with_unbundled_env { Open3.capture2e(env, command, chdir: chdir) }
  end

  def run3(command, chdir: Dir.pwd, env: {})
    Bundler.with_unbundled_env { Open3.capture3(env, command, chdir: chdir) }
  end
end
