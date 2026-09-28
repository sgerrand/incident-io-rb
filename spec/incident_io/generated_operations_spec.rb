# frozen_string_literal: true

# Calls every generated resource method listed in spec/fixtures/operations.json
# (written by `rake generate`) and checks the request it sends and the result
# it returns.
RSpec.describe "generated resource methods" do
  manifest = JSON.parse(File.read(File.expand_path("../fixtures/operations.json", __dir__)))

  let(:client) { IncidentIo::Client.new(api_key: "k", max_retries: 0) }

  def response_for(result)
    case result["kind"]
    when "none" then {status: 204}
    when "text" then {status: 200, body: "a,b\n", headers: {"Content-Type" => "text/csv"}}
    when "paginated" then json_response({result["items_key"] => [nest({}, result["depth"])], "pagination_meta" => {}})
    else
      value = nest({}, result["depth"])
      json_response(result["unwrap"] ? {result["unwrap"] => value} : value)
    end
  end

  # The value wrapped in depth arrays, e.g. nest({}, 2) is [[{}]].
  def nest(value, depth)
    depth.times.reduce(value) { |inner, _| [inner] }
  end

  def model_class(result)
    result["model"] && IncidentIo::Models.const_get(result["model"])
  end

  manifest.each do |op|
    it "#{op["operation_id"]}: client.#{op["version"]}.#{op["resource"]}.#{op["method"]}" do
      args = op["path_args"].dup
      path = op["path"].gsub(/\{\w+\}/) { IncidentIo::Util.escape_path(args.shift) }
      url = /\A#{Regexp.escape("#{BASE_URL}#{path}")}(\?|\z)/
      sent = nil
      stub_request(op["http_method"].to_sym, url).with { |request| sent = request }.to_return(response_for(op["result"]))

      kwargs = op["keyword_args"].transform_keys(&:to_sym)
      kwargs[op["null_body_key"].to_sym] = nil if op["null_body_key"]
      resource = client.public_send(op["version"]).public_send(op["resource"])
      result = resource.public_send(op["method"], *op["path_args"], **kwargs)
      result = result.to_a if op["result"]["kind"] == "paginated"

      expect(sent).not_to be_nil, "expected #{op["http_method"].upcase} #{path}"
      query_keys = URI.decode_www_form(sent.uri.query.to_s).map(&:first)
      op["query_keys"].each do |key|
        expect(query_keys).to include(satisfy { |q| q == key || q.start_with?("#{key}[") })
      end

      if op["body"]
        body = JSON.parse(sent.body)
        op["body_keys"].each { |key| expect(body[key]).to eq(op["keyword_args"][key]) }
        expect(body["idempotency_key"]).to match(/\A\h{8}-\h{4}-/) if op["idempotency_key"]
        # Optional fields that weren't passed are left out; nil is sent as null.
        expect(body.keys).to match_array(op["body_keys"] + [op["null_body_key"], ("idempotency_key" if op["idempotency_key"])].compact)
        expect(body).to include(op["null_body_key"] => nil) if op["null_body_key"]
      else
        expect(sent.body.to_s).to be_empty
      end

      model = model_class(op["result"])
      case op["result"]["kind"]
      when "none" then expect(result).to be_nil
      when "text" then expect(result).to eq("a,b\n")
      when "paginated"
        expect(result.size).to eq(1)
        expect(result.first).to match(nest(be_a(model), op["result"]["depth"])) if model
      else
        expected = model ? be_a(model) : {}
        expect(result).to match(nest(expected, op["result"]["depth"]))
      end
    end
  end

  it "reaches every resource through its version and, for the newest version, directly" do
    by_name = manifest.group_by { |op| op["resource"] }

    by_name.each do |name, ops|
      versions = ops.map { |op| op["version"] }.uniq
      versions.each { |v| expect(client.public_send(v).public_send(name)).to be_a(IncidentIo::Resource) }

      newest = versions.max_by { |v| v.delete_prefix("v").to_i }
      expect(client.public_send(name)).to be_a(client.public_send(newest).public_send(name).class)
    end
  end

  it "loads with require \"incident-io\" too" do
    expect { require "incident-io" }.not_to raise_error
  end

  it "keeps version namespaces out of #inspect output" do
    %w[v1 v2 v3].each { |v| expect(client.public_send(v).inspect).to match(/\A#<IncidentIo::Resources::V\d::Namespace>\z/) }
  end
end
