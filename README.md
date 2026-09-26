# incident-io

A Ruby client for the incident.io API.

Needs Ruby 3.3 or newer.

## Usage

The typed resources (`client.incidents` and so on) are not built yet. For now,
use the low-level client. It handles auth, JSON, errors, retries and paging.

```ruby
require "incident_io"

client = IncidentIo::Client.new(api_key: ENV["INCIDENT_IO_API_KEY"])

# One request. Returns the parsed JSON body.
client.request(:get, "/v2/incidents/01ABC")

# Every item of a list, fetched page by page as you go.
client.paginate(
  "/v2/incidents",
  items_key: "incidents",
  query: { page_size: 100, status_category: { one_of: ["active"] } }
).each { |incident| puts incident["name"] }
```

### Errors

Failed requests raise a subclass of `IncidentIo::APIError`, for example
`NotFoundError`, `UnprocessableEntityError` or `RateLimitError`. Each error has
`status`, `type`, `request_id` and `errors` (the field-level details).

Network problems raise `IncidentIo::APIConnectionError` or
`IncidentIo::APITimeoutError`.

### Retries

The client retries up to 2 times (change this with `max_retries:`):

- rate limits (429), waiting as long as the API asks, up to 60 seconds
- server errors and network errors, but only for GET, PUT and DELETE, or for
  a POST sent with `idempotent: true`

## Development

```sh
bundle install
bundle exec rake
```
