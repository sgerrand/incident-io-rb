# frozen_string_literal: true

RSpec.describe IncidentIo::Util do
  describe ".serialize" do
    it "turns keys into strings and values into JSON-ready values" do
      point = Data.define(:x, :y)

      expect(described_class.serialize(
        {at: Time.utc(2024, 5, 1, 12), on: Date.new(2024, 5, 1), dt: DateTime.new(2024, 5, 1, 12),
         kind: :big, point: point.new(x: 1, y: 2), list: [:a]}
      )).to eq(
        "at" => "2024-05-01T12:00:00.000Z", "on" => "2024-05-01", "dt" => "2024-05-01T12:00:00.000Z",
        "kind" => "big", "point" => {"x" => 1, "y" => 2}, "list" => ["a"]
      )
    end
  end

  describe ".escape_path" do
    it "escapes characters that would change the path" do
      expect(described_class.escape_path("a/../b c")).to eq("a%2F..%2Fb%20c")
    end
  end

  describe ".parse_time" do
    it "parses ISO 8601 and HTTP dates" do
      expect(described_class.parse_time("2024-05-01T12:00:00Z")).to eq(Time.utc(2024, 5, 1, 12))
      expect(described_class.parse_time("Wed, 01 May 2024 12:00:00 GMT", httpdate: true)).to eq(Time.utc(2024, 5, 1, 12))
    end

    it "returns Times as they are and nil for blank or bad values" do
      time = Time.now

      expect(described_class.parse_time(time)).to be(time)
      expect([nil, "", "soon"].map { |v| described_class.parse_time(v) }).to all(be_nil)
    end
  end

  describe "IncidentIo::NOT_GIVEN" do
    it "reads well when printed" do
      expect([IncidentIo::NOT_GIVEN.inspect, IncidentIo::NOT_GIVEN.to_s]).to all(eq("IncidentIo::NOT_GIVEN"))
      expect(IncidentIo::NOT_GIVEN).to be_frozen
    end
  end
end
