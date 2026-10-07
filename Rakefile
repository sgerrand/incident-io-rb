require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

task default: :spec

# Standard's `standard` and `standard:fix` tasks. Only there when the lint
# gems are installed.
begin
  require "standard/rake"
rescue LoadError
  nil
end

namespace :spec do
  desc "Run the specs, checking every call into the gem against sig/ with rbs test"
  task :rbs do
    env = {
      "RBS_TEST_TARGET" => "IncidentIo::*",
      "RBS_TEST_OPT" => "-I sig -r date -r json -r logger -r net-http -r openssl -r securerandom -r time -r uri",
      "RBS_TEST_DOUBLE_SUITE" => "rspec",
      "RBS_TEST_LOGLEVEL" => "error",
      "RUBYOPT" => "#{ENV["RUBYOPT"]} -rbundler/setup -rrbs/test/setup".strip
    }
    sh env, "rspec"
  end
end

desc "Check the YARD docs in lib/ with Yardstick (see .yardstick.yml)"
task :yardstick do
  require "yaml"
  require "yardstick"

  config = Yardstick::Config.coerce(YAML.safe_load_file(".yardstick.yml"))
  measurements = Yardstick.measure(config)
  measurements.puts
  coverage = (measurements.coverage * 100).to_f

  abort "Yardstick: #{coverage.round(1)}% is below the #{config.threshold}% threshold" if coverage < config.threshold
end

desc "Type-check lib/ against the signatures in sig/ with Steep"
task :typecheck do
  sh "steep", "check"
end

SPEC_FILE = "openapi/openapi.json"

# The spec is not stored in git, so generating needs a local copy.
def require_spec!
  return if File.exist?(SPEC_FILE)

  abort "#{SPEC_FILE} is missing. Run `rake openapi:fetch` first."
end

namespace :openapi do
  desc "Download the latest incident.io OpenAPI spec to #{SPEC_FILE}"
  task :fetch do
    require "fileutils"
    require "json"
    require "net/http"

    url = URI("https://api.incident.io/v1/openapiV3.json")
    response = Net::HTTP.get_response(url)
    abort "Could not download #{url}: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    FileUtils.mkdir_p(File.dirname(SPEC_FILE))
    File.write(SPEC_FILE, "#{JSON.pretty_generate(JSON.parse(response.body))}\n")
    puts "Saved #{SPEC_FILE}. Now run `rake generate`."
  end
end

desc "Generate models and resources from #{SPEC_FILE}"
task :generate do
  require_spec!
  require_relative "generator/incident_io_generator"

  files = IncidentIoGenerator.generate
  puts "Generated #{files.size} files."
end

namespace :generate do
  desc "List breaking changes in the generated code since the last commit"
  task :breaking do
    require "open3"
    require "tmpdir"
    require_relative "generator/incident_io_generator"

    Dir.mktmpdir do |dir|
      # Unpack the manifests as they were at the last commit.
      paths = IncidentIoGenerator::BreakingChanges::PATHS
      statuses = Open3.pipeline(["git", "archive", "HEAD", "--", *paths], ["tar", "-x", "-C", dir])
      abort "Could not read the manifests from the last commit." unless statuses.all?(&:success?)

      print IncidentIoGenerator::BreakingChanges.report(dir, IncidentIoGenerator::ROOT)
    end
  end

  desc "Fail if the generated code does not match #{SPEC_FILE}"
  task :check do
    require_spec!
    require "tmpdir"
    require_relative "generator/incident_io_generator"

    Dir.mktmpdir do |dir|
      root = IncidentIoGenerator::ROOT
      files = IncidentIoGenerator.generate(root: dir)
      committed = IncidentIoGenerator::Writer::GENERATED.flat_map do |path|
        File.directory?(File.join(root, path)) ? Dir.glob("#{path}/**/*.{rb,rbs}", base: root) : [path]
      end

      stale = files.reject do |path|
        committed_path = File.join(root, path)
        File.exist?(committed_path) && File.read(committed_path) == File.read(File.join(dir, path))
      end
      extra = committed - files

      if stale.any? || extra.any?
        warn "Generated code is out of date. Run `rake generate`."
        stale.first(20).each { |path| warn "  changed: #{path}" }
        extra.first(20).each { |path| warn "  not generated: #{path}" }
        abort
      end

      puts "Generated code is up to date."
    end
  end
end
