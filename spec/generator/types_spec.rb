# frozen_string_literal: true

require_relative "generator_helper"

RSpec.describe IncidentIoGenerator::Types do
  it "maps schemas to model types" do
    expect(described_class.model_type({ "$ref" => "#/components/schemas/IncidentV2" })).to eq("-> { IncidentV2 }")
    expect(described_class.model_type({ "type" => "string", "format" => "date-time" })).to eq(":time")
    expect(described_class.model_type({ "type" => "string", "format" => "date" })).to eq(":date")
    expect(described_class.model_type({ "type" => "integer", "format" => "int64" })).to eq(":integer")
    expect(described_class.model_type({ "type" => "number" })).to eq(":float")
    expect(described_class.model_type({ "type" => "boolean" })).to eq(":boolean")
    expect(described_class.model_type({ "type" => "array", "items" => { "type" => "string" } })).to eq("[:string]")
    expect(described_class.model_type({ "type" => "object", "additionalProperties" => { "type" => "string" } }))
      .to eq("Model.map_of(:string)")
    expect(described_class.model_type({ "type" => "object", "properties" => {} })).to eq(":any")
    expect(described_class.model_type({})).to eq(":any")
  end

  it "maps response schemas to result types" do
    expect(described_class.result_type({ "$ref" => "#/components/schemas/X" })).to eq("Models::X")
    expect(described_class.result_type({ "type" => "array", "items" => { "$ref" => "#/c/X" } })).to eq("[Models::X]")
    expect(described_class.result_type({ "type" => "string" })).to be_nil
  end

  it "maps schemas to YARD types" do
    expect(described_class.yard_type({ "type" => "array", "items" => { "$ref" => "#/c/X" } })).to eq("Array<Models::X>")
    expect(described_class.yard_type({ "$ref" => "#/c/X" }, accepts_hash: true)).to eq("Models::X, Hash")
    expect(described_class.yard_type({ "type" => "object", "additionalProperties" => { "type" => "integer" } }))
      .to eq("Hash{String => Integer}")
  end
end
