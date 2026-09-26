# frozen_string_literal: true

require "erb"
require "fileutils"
require "json"
require "yaml"

require_relative "../lib/incident_io/model"
require_relative "incident_io_generator/naming"
require_relative "incident_io_generator/types"
require_relative "incident_io_generator/api"
require_relative "incident_io_generator/writer"

# Generates IncidentIo models and resources from the incident.io OpenAPI spec.
module IncidentIoGenerator
  ROOT = File.expand_path("..", __dir__)
  SPEC_PATH = File.join(ROOT, "openapi", "openapi.json")
  OVERRIDES_PATH = File.join(__dir__, "overrides.yml")
  OUT_DIR = File.join(ROOT, "lib", "incident_io")

  module_function

  def load_api(spec_path: SPEC_PATH, overrides_path: OVERRIDES_PATH)
    spec = JSON.parse(File.read(spec_path))
    overrides = File.exist?(overrides_path) ? YAML.safe_load_file(overrides_path) || {} : {}
    Api.new(spec, overrides)
  end

  # Writes the generated files and returns their paths.
  def generate(out_dir: OUT_DIR, **options)
    Writer.new(load_api(**options), out_dir).write
  end
end
