# frozen_string_literal: true

# Not run. Steep type-checks this file against sig/ to make sure the
# signatures work for typical calls. See the :usage target in Steepfile.

client = IncidentIo::Client.new(api_key: "key", timeout: 30, max_retries: 3)

incident = client.incidents.create(name: "Database is down", visibility: "public")
incident.id&.upcase
incident.created_at&.iso8601
incident.severity&.name
incident[:field_added_later]
incident.to_api.fetch("name", nil)

client.incidents.edit(
  "01ABC",
  incident: IncidentIo::Models::IncidentEditPayloadV2.new(name: "New name"),
  notify_incident_channel: false
)
client.incidents.edit("01ABC", incident: {name: "New name"}, notify_incident_channel: false)

client.incidents.list(page_size: 100, status_category: {one_of: ["live"]}).each do |item|
  item.name&.length
end
client.incidents.list.first(10).map(&:id)
client.incidents.list.each_page { |page| page.total_record_count }

client.catalog.list_entries(catalog_type_id: "01TYPE", page_size: 25).first_page.data["catalog_type"]
client.v2.catalog.list_types
client.pay_reports.download("01REPORT").lines
client.schedules.destroy("01SCHED")

client.incidents.show("01ABC", request_options: {api_key: "other", timeout: 5})
client.request(:get, "/v2/incidents", query: {page_size: 1})

begin
  client.incidents.show("missing")
rescue IncidentIo::RateLimitError => e
  e.retry_after&.ceil
rescue IncidentIo::APIError => e
  e.errors.map(&:message)
  e.request_id
end

event = IncidentIo::Webhook.construct_event(
  '{"event_type": "public_incident.incident_created_v2"}',
  {"webhook-id" => "msg_1", "webhook-timestamp" => "1", "webhook-signature" => "v1,x"},
  secret: "whsec_c2VjcmV0"
)
case (data = event.data)
when IncidentIo::Models::WebhookIncidentV2 then data.name&.upcase
when IncidentIo::Models::WebhookPrivateResourceV2 then client.incidents.show(data.id || "")
end
event.id&.length

entry = IncidentIo::AuditLog.parse('{"action": "alert_route.created", "version": 1}')
entry.actor&.name if entry.is_a?(IncidentIo::Models::AuditLogsAlertRouteCreatedV1)
