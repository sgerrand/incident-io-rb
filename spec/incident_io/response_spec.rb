# frozen_string_literal: true

RSpec.describe IncidentIo::Response do
  def response(body, content_type = "application/json")
    described_class.new(status: 200, headers: {"content-type" => content_type}, body:)
  end

  it "parses JSON bodies" do
    expect(response('{"a": 1}').parsed).to eq("a" => 1)
  end

  it "returns other bodies as text" do
    expect(response("a,b", "text/csv").parsed).to eq("a,b")
  end

  it "returns the text of a JSON body it can't parse" do
    expect(response("<html>oops</html>").parsed).to eq("<html>oops</html>")
  end

  it "returns nil for an empty body" do
    expect([response(nil).parsed, response("").parsed]).to eq([nil, nil])
  end
end
