# frozen_string_literal: true

require_relative "generator_helper"

RSpec.describe IncidentIoGenerator::Naming do
  {
    "IncidentV2" => "incident_v2",
    "Follow-ups" => "follow_ups",
    "IPAllowlists" => "ip_allowlists",
    "API Keys" => "api_keys",
    "CreateHTTP" => "create_http",
    "IncidentParticipants" => "incident_participants",
    "ListScheduleEntries" => "list_schedule_entries"
  }.each do |input, expected|
    it "underscores #{input.inspect} as #{expected.inspect}" do
      expect(described_class.underscore(input)).to eq(expected)
    end
  end

  it "camelizes" do
    expect(described_class.camelize("Follow-ups")).to eq("FollowUps")
    expect(described_class.camelize("API Keys")).to eq("ApiKeys")
  end

  it "knows safe identifiers" do
    expect(described_class.safe_identifier?("page_size")).to be(true)
    expect(described_class.safe_identifier?("end")).to be(false)
    expect(described_class.safe_identifier?("x-y")).to be(false)
  end
end
