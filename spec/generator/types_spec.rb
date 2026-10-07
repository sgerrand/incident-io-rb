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

  it "maps response schemas to result models" do
    expect(described_class.result_model({"$ref" => "#/components/schemas/X"})).to eq(model_name: "X", depth: 0)
    expect(described_class.result_model({"type" => "array", "items" => {"$ref" => "#/c/X"}})).to eq(model_name: "X", depth: 1)
    expect(described_class.result_model({"type" => "array", "items" => {"type" => "string"}})).to eq({})
    expect(described_class.result_model({"type" => "array"})).to eq({})
    expect(described_class.result_model({"type" => "string"})).to eq({})
    expect(described_class.result_model(nil)).to eq({})
  end

  it "keeps models in arrays of arrays" do
    nested = {"type" => "array", "items" => {"type" => "array", "items" => {"$ref" => "#/c/X"}}}

    expect(described_class.result_model(nested)).to eq(model_name: "X", depth: 2)
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

  it "reads the values a schema is limited to" do
    expect(described_class.allowed_values({"type" => "string", "enum" => %w[a b]})).to eq(%w[a b])
    expect(described_class.allowed_values({"type" => "array", "items" => {"type" => "string", "enum" => %w[a b]}})).to eq(%w[a b])
    expect(described_class.allowed_values({"type" => "string"})).to be_nil
  end

  it "reads the values of nested arrays and maps" do
    values = {"type" => "string", "enum" => %w[a b]}
    array = {"type" => "array", "items" => values}

    expect(described_class.allowed_values({"type" => "array", "items" => array})).to eq(%w[a b])
    expect(described_class.allowed_values({"type" => "object", "additionalProperties" => values})).to eq(%w[a b])
    expect(described_class.allowed_values({"type" => "object", "additionalProperties" => array})).to eq(%w[a b])
    expect(described_class.allowed_values({"type" => "object", "additionalProperties" => true})).to be_nil
    expect(described_class.allowed_values({"type" => "array", "items" => {"type" => "object"}})).to be_nil
  end
  it "reads the limits of a schema and of the keys inside it" do
    size = {"type" => "string", "enum" => %w[s m]}
    box = {"type" => "object", "properties" => {"size" => size, "label" => {"type" => "string"}}}

    expect(described_class.limits(size, "size")).to eq("size" => %w[s m])
    expect(described_class.limits({"type" => "string"}, "name")).to eq({})
    expect(described_class.limits(box, "box")).to eq("box.size" => %w[s m])
    expect(described_class.limits({"type" => "array", "items" => box}, "boxes")).to eq("boxes.size" => %w[s m])
    expect(described_class.limits({"type" => "object", "properties" => {"inner" => box}}, "outer")).to eq("outer.inner.size" => %w[s m])
  end

  it "reads the limits of keys inside nested arrays and maps" do
    box = {"type" => "object", "properties" => {"size" => {"type" => "string", "enum" => %w[s m]}}}
    boxes = {"type" => "array", "items" => box}

    expect(described_class.limits({"type" => "array", "items" => boxes}, "rows")).to eq("rows.size" => %w[s m])
    expect(described_class.limits({"type" => "object", "additionalProperties" => box}, "by_id")).to eq("by_id.size" => %w[s m])
    expect(described_class.limits({"type" => "object", "additionalProperties" => boxes}, "by_id")).to eq("by_id.size" => %w[s m])
    expect(described_class.limits({"type" => "array", "items" => {"type" => "object", "additionalProperties" => boxes}}, "rows"))
      .to eq("rows.size" => %w[s m])
    expect(described_class.limits({"type" => "object", "additionalProperties" => true}, "anything")).to eq({})
  end

  it "reads the operators a description names" do
    {
      "Filter on status. The accepted operators are 'one_of', or 'not_in'." => %w[one_of not_in],
      "Accepted operators are 'gte', 'lte' and 'date_range'." => %w[gte lte date_range],
      "The accepted operator is 'is'." => %w[is],
      "The accepted operators are 'one_of, or 'not_in'." => %w[one_of not_in],
      "The accepted operators are 'one_of' and 'date-range' on the widget's kind." => %w[one_of date-range],
      %(The accepted operators are `one_of` and "not_in".) => %w[one_of not_in],
      "The accepted operators are listed in the guide." => nil,
      "Custom field ID should be sent, followed by the operator and values." => nil,
      nil => nil
    }.each { |text, operators| expect(described_class.operators(text)).to eq(operators) }
  end
  it "reads the operators that examples show" do
    text = "Try `--data 'custom_field[ABC][not_in]=XYZ'` or `tags[all_of]=x`, but not other_custom_field[ABC][gte]=1."

    expect(described_class.example_operators("custom_field", {"01ABC" => {"one_of" => %w[x y]}}, text)).to eq(%w[one_of not_in])
    expect(described_class.example_operators("tags", {"one_of" => ["x"], "all_of" => ["y"]}, text)).to eq(%w[one_of all_of])
    expect(described_class.example_operators("role", {"01ABC" => {"01DEF" => {"is_blank" => ["true"]}}}, nil)).to eq(%w[is_blank])
    expect(described_class.example_operators("query", nil, nil)).to eq([])
  end
end
