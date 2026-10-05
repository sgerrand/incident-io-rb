# frozen_string_literal: true

require_relative "generator_helper"

RSpec.describe IncidentIoGenerator::RemovedTypes do
  let(:events_path) { "lib/incident_io/webhook_events.rb" }
  let(:entries_path) { "lib/incident_io/audit_log_entries.rb" }
  let(:events) do
    <<~RUBY
      EVENTS = {
        # A widget was created.
        "public_widget.created_v1" => :WidgetV2,
        "public_widget.deleted_v1" => :WidgetV2
      }.freeze
    RUBY
  end
  let(:entries) do
    <<~RUBY
      ENTRIES = {
        ["widget.created", 1] => :AuditLogsWidgetCreatedV1,
        ["widget.deleted", 2] => :AuditLogsWidgetDeletedV2
      }.freeze
    RUBY
  end

  it "reads the types from a generated map" do
    expect(described_class.types(events)).to eq(%w[`public_widget.created_v1` `public_widget.deleted_v1`])
    expect(described_class.types(entries)).to eq(["`widget.created` (version 1)", "`widget.deleted` (version 2)"])
  end

  it "reads every type in the generated code" do
    described_class::FILES.each_key do |path|
      source = File.read(File.join(IncidentIoGenerator::ROOT, path))

      expect(described_class.types(source).size).to eq(source.scan(" => :").size)
    end
  end

  it "lists the types that were removed" do
    after = {
      events_path => events.sub(/^.*deleted_v1.*\n/, ""),
      entries_path => entries.sub(/^.*widget\.created.*\n/, "")
    }

    expect(described_class.report({events_path => events, entries_path => entries}, after)).to eq(<<~MARKDOWN)
      ## Removed types

      The latest spec no longer has these types. The gem will stop building models for them, which can break code that uses it.

      - Webhook event `public_widget.deleted_v1`
      - Audit log entry `widget.created` (version 1)
    MARKDOWN
  end

  it "lists every type of a file that is gone" do
    expect(described_class.report({events_path => events}, {})).to include("`public_widget.created_v1`", "`public_widget.deleted_v1`")
  end

  it "is empty when types were only added" do
    before = {events_path => events.sub(/^.*deleted_v1.*\n/, ""), entries_path => entries}

    expect(described_class.report(before, {events_path => events, entries_path => entries})).to eq("")
  end
end
