# frozen_string_literal: true

require_relative "generator_helper"

RSpec.describe IncidentIoGenerator::Types do
  it "maps schemas to model types" do
    expect(described_class.model_type({"$ref" => "#/components/schemas/IncidentV2"})).to eq("-> { IncidentV2 }")
    expect(described_class.model_type({"type" => "string", "format" => "date-time"})).to eq(":time")
    expect(described_class.model_type({"type" => "string", "format" => "date"})).to eq(":date")
    expect(described_class.model_type({"type" => "integer", "format" => "int64"})).to eq(":integer")
    expect(described_class.model_type({"type" => "number"})).to eq(":float")
    expect(described_class.model_type({"type" => "boolean"})).to eq(":boolean")
    expect(described_class.model_type({"type" => "array", "items" => {"type" => "string"}})).to eq("[:string]")
    expect(described_class.model_type({"type" => "object", "additionalProperties" => {"type" => "string"}}))
      .to eq("Model.map_of(:string)")
    expect(described_class.model_type({"type" => "object", "properties" => {}})).to eq(":any")
    expect(described_class.model_type({})).to eq(":any")
  end

  it "maps response schemas to result types" do
    expect(described_class.result_type({"$ref" => "#/components/schemas/X"})).to eq("Models::X")
    expect(described_class.result_type({"type" => "array", "items" => {"$ref" => "#/c/X"}})).to eq("[Models::X]")
    expect(described_class.result_type({"type" => "string"})).to be_nil
  end

  it "maps schemas to YARD types" do
    expect(described_class.yard_type({"type" => "array", "items" => {"$ref" => "#/c/X"}})).to eq("Array<Models::X>")
    expect(described_class.yard_type({"$ref" => "#/c/X"}, accepts_hash: true)).to eq("Models::X, Hash")
    expect(described_class.yard_type({"type" => "object", "additionalProperties" => {"type" => "integer"}}))
      .to eq("Hash{String => Integer}")
  end
  it "maps schemas to RBS types" do
    expect(described_class.rbs_type({"$ref" => "#/c/X"})).to eq("Models::X")
    expect(described_class.rbs_type({"$ref" => "#/c/X"}, input: true)).to eq("Models::X | Hash[untyped, untyped]")
    expect(described_class.rbs_type({"type" => "string", "format" => "date-time"})).to eq("Time")
    expect(described_class.rbs_type({"type" => "string", "format" => "date-time"}, input: true)).to eq("Time | String")
    expect(described_class.rbs_type({"type" => "number"}, input: true)).to eq("Numeric")
    expect(described_class.rbs_type({"type" => "boolean"})).to eq("bool")
    expect(described_class.rbs_type({"type" => "object", "additionalProperties" => {"type" => "string"}}))
      .to eq("Hash[String, String]")
    expect(described_class.rbs_type({"type" => "object"}, input: true)).to eq("Hash[untyped, untyped]")
    expect(described_class.rbs_type({})).to eq("untyped")
  end

  it "makes RBS types nilable" do
    expect(described_class.rbs_optional("String")).to eq("String?")
    expect(described_class.rbs_optional("A | B")).to eq("(A | B)?")
    expect(described_class.rbs_optional("Array[A | B]")).to eq("Array[A | B]?")
    expect(described_class.rbs_optional("untyped")).to eq("untyped")
  end

  it "maps more schemas to YARD types" do
    expect(described_class.yard_type({"type" => "string", "format" => "date"})).to eq("Date")
    expect(described_class.yard_type({"type" => "number"})).to eq("Float")
    expect(described_class.yard_type({"type" => "boolean"})).to eq("Boolean")
    expect(described_class.yard_type({"type" => "object"})).to eq("Hash")
    expect(described_class.yard_type({})).to eq("Object")
  end

  it "maps more schemas to RBS types" do
    expect(described_class.rbs_type({"type" => "string", "format" => "date"}, input: true)).to eq("Date | String")
    expect(described_class.rbs_type({"type" => "string", "format" => "date"})).to eq("Date")
    expect(described_class.rbs_type({"type" => "number"})).to eq("Float")
    expect(described_class.rbs_type({"type" => "integer"})).to eq("Integer")
    expect(described_class.rbs_type({"type" => "object"})).to eq("Hash[String, untyped]")
    expect(described_class.rbs_type({"type" => "array", "items" => {"type" => "string"}})).to eq("Array[String]")
  end

  it "maps results to RBS return types" do
    expect(described_class.rbs_result(nil)).to eq("untyped")
    expect(described_class.rbs_result({"$ref" => "#/c/X"})).to eq("Models::X")
    expect(described_class.rbs_result({"type" => "array", "items" => {"$ref" => "#/c/X"}})).to eq("Array[Models::X]")
    expect(described_class.rbs_result({"type" => "string"})).to eq("untyped")
    expect(described_class.result_type(nil)).to be_nil
  end

  it "makes sample values for tests" do
    samples = {
      {"$ref" => "#/c/X"} => {},
      {"type" => "string"} => "n-value",
      {"type" => "string", "enum" => %w[a b]} => "a",
      {"type" => "string", "format" => "date-time"} => "2024-01-01T00:00:00Z",
      {"type" => "string", "format" => "date"} => "2024-01-01",
      {"type" => "integer"} => 1,
      {"type" => "number"} => 1.5,
      {"type" => "boolean"} => true,
      {"type" => "array", "items" => {"type" => "integer"}} => [1],
      {"type" => "object"} => {"one_of" => ["n-value"]},
      {} => "n-value"
    }

    samples.each { |schema, sample| expect(described_class.sample_value(schema, "n")).to eq(sample) }
  end
end
