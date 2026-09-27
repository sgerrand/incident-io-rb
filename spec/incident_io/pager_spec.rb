# frozen_string_literal: true

RSpec.describe IncidentIo::Pager do
  let(:client) { IncidentIo::Client.new(api_key: "k") }
  let(:url) { "#{BASE_URL}/v2/incidents" }
  let(:incident) { IncidentIo::Model.define(id: :string) }

  def page(ids, after:, total: nil)
    meta = {"page_size" => 2, "after" => after}
    meta["total_record_count"] = total if total
    json_response({"incidents" => ids.map { |id| {"id" => id} }, "pagination_meta" => meta})
  end

  before do
    stub_request(:get, url).with(query: {"page_size" => "2"}).to_return(page(%w[1 2], after: "2", total: 5))
    stub_request(:get, url).with(query: {"page_size" => "2", "after" => "2"}).to_return(page(%w[3 4], after: "4"))
    stub_request(:get, url).with(query: {"page_size" => "2", "after" => "4"}).to_return(page(%w[5], after: nil))
  end

  it "walks every page" do
    pager = client.paginate("/v2/incidents", items_key: "incidents", query: {page_size: 2})

    expect(pager.map { |i| i["id"] }).to eq(%w[1 2 3 4 5])
  end

  it "fetches only the pages it needs" do
    pager = client.paginate("/v2/incidents", items_key: "incidents", query: {page_size: 2})

    expect(pager.first(3).map { |i| i["id"] }).to eq(%w[1 2 3])
    expect(a_request(:get, url).with(query: {"page_size" => "2", "after" => "4"})).not_to have_been_made
  end

  it "builds models" do
    pager = client.paginate("/v2/incidents", items_key: "incidents", query: {page_size: 2}, model: incident)

    expect(pager.first).to eq(incident.new(id: "1"))
  end

  it "exposes page metadata" do
    first = client.paginate("/v2/incidents", items_key: "incidents", query: {page_size: 2}).first_page

    expect(first).to have_attributes(after: "2", page_size: 2, total_record_count: 5)
    expect(first.next_page?).to be(true)
    expect(first.next_page.map { |i| i["id"] }).to eq(%w[3 4])
  end

  it "walks every page with auto_paging_each too" do
    pager = client.paginate("/v2/incidents", items_key: "incidents", query: {page_size: 2})

    ids = []
    pager.auto_paging_each { |i| ids << i["id"] }

    expect(ids).to eq(%w[1 2 3 4 5])
    expect(pager.auto_paging_each).to be_a(Enumerator)
  end

  it "returns enumerators without a block" do
    pager = client.paginate("/v2/incidents", items_key: "incidents", query: {page_size: 2})

    expect(pager.each).to be_a(Enumerator)
    expect(pager.first_page.each.map { |i| i["id"] }).to eq(%w[1 2])
  end

  it "yields pages" do
    pages = client.paginate("/v2/incidents", items_key: "incidents", query: {page_size: 2}).each_page.to_a

    expect(pages.map(&:count)).to eq([2, 2, 1])
  end

  it "starts from a given cursor" do
    pager = client.paginate("/v2/incidents", items_key: "incidents", query: {page_size: 2, after: "4"})

    expect(pager.map { |i| i["id"] }).to eq(%w[5])
  end

  it "stops if the API repeats the cursor" do
    stub_request(:get, url).with(query: {"after" => "x"}).to_return(page(%w[9], after: "x"))

    expect(client.paginate("/v2/incidents", items_key: "incidents", query: {after: "x"}).to_a.size).to eq(1)
  end

  it "stops on an empty page" do
    stub_request(:get, url).with(query: {"after" => "y"}).to_return(page([], after: "z"))

    expect(client.paginate("/v2/incidents", items_key: "incidents", query: {after: "y"}).to_a).to eq([])
  end
end
