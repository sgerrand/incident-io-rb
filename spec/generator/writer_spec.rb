# frozen_string_literal: true

require "tmpdir"
require_relative "generator_helper"

RSpec.describe IncidentIoGenerator::Writer, :generator do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  let(:api) { IncidentIoGenerator::Api.new(mini_spec) }

  def generated(path)
    File.read(File.join(@dir, path))
  end

  it "writes index, model and resource files" do
    files = described_class.new(api, @dir).write

    expect(files).to contain_exactly(
      "models.rb", "models/part_v2.rb", "models/pagination_meta_result_v2.rb", "models/widget_v2.rb",
      "models/widgets_create_payload_v2.rb", "models/widgets_list_result_v2.rb", "models/widgets_show_result_v2.rb",
      "resources.rb", "resources/v2/widgets.rb"
    )
  end

  it "writes valid Ruby" do
    files = described_class.new(api, @dir).write

    files.each do |path|
      expect { RubyVM::InstructionSequence.compile(generated(path)) }.not_to raise_error, path
    end
  end

  it "removes files left over from an earlier run" do
    FileUtils.mkdir_p(File.join(@dir, "models"))
    File.write(File.join(@dir, "models", "gone_v1.rb"), "")

    described_class.new(api, @dir).write

    expect(File).not_to exist(File.join(@dir, "models", "gone_v1.rb"))
  end

  it "generates idiomatic methods" do
    described_class.new(api, @dir).write
    source = generated("resources/v2/widgets.rb")

    expect(source).to include("def create(name:, idempotency_key: SecureRandom.uuid, part: nil, request_options: {})")
    expect(source).to include("def show(id, request_options: {})")
    expect(source).to include('path("/v2/widgets/%s", id)')
    expect(source).to include('deprecated!("client.v2.widgets.destroy")')
    expect(source).to include("# @param part [Models::PartV2, Hash]")
    expect(source).to include("# Endpoint: `GET /v2/widgets`. Scopes: widgets.read.")
  end

  it "generates models with lazy references" do
    described_class.new(api, @dir).write
    source = generated("models/widget_v2.rb")

    expect(source).to include("    WidgetV2 = Model.define(\n      id: :string,\n      class: :string,")
    expect(source).to include("parts: [-> { PartV2 }]")
    expect(source).to include("# @!attribute [r] class_")
  end
end
