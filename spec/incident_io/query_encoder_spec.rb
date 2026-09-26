# frozen_string_literal: true

RSpec.describe IncidentIo::QueryEncoder do
  def decode(query)
    URI.decode_www_form(query)
  end

  it "encodes scalars" do
    expect(decode(described_class.encode(page_size: 50, after: "01ABC"))).to eq([%w[page_size 50], %w[after 01ABC]])
  end

  it "encodes deepObject filters and repeats the key for each array value" do
    query = described_class.encode(status: {one_of: %w[a b]})

    expect(decode(query)).to eq([["status[one_of]", "a"], ["status[one_of]", "b"]])
  end

  it "encodes two-level filters such as custom_field" do
    query = described_class.encode(custom_field: {"01F" => {one_of: ["x"]}})

    expect(decode(query)).to eq([["custom_field[01F][one_of]", "x"]])
  end

  it "repeats the key for top-level arrays" do
    expect(decode(described_class.encode(team_ids: %w[t1 t2]))).to eq([%w[team_ids t1], %w[team_ids t2]])
  end

  it "leaves out nil values" do
    expect(described_class.encode(after: nil, page_size: 10)).to eq("page_size=10")
  end

  it "formats times, dates and booleans" do
    query = described_class.encode(
      created_at: {gte: [Time.utc(2024, 5, 1, 12)]},
      on: Date.new(2024, 5, 1),
      flag: true
    )

    expect(decode(query)).to eq([["created_at[gte]", "2024-05-01T12:00:00Z"], %w[on 2024-05-01], %w[flag true]])
  end

  it "returns an empty string for nil or empty params" do
    expect(described_class.encode(nil)).to eq("")
    expect(described_class.encode({})).to eq("")
  end
end
