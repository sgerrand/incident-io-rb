require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

task default: :spec

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
  puts "Generated #{files.size} files in lib/incident_io and sig/incident_io."
end

namespace :generate do
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
