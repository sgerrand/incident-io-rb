# incident-io

A Ruby client for the incident.io API.

Needs Ruby 3.3 or newer.

## Usage

```ruby
require "incident_io"

client = IncidentIo::Client.new(api_key: ENV["INCIDENT_IO_API_KEY"])

incident = client.incidents.create(name: "Database is down", visibility: "public")
incident.id          # => "01H..."
incident.created_at  # => a Time

# Lists fetch pages as you go.
client.incidents.list(status_category: { one_of: ["live"] }).each do |incident|
  puts incident.name
end
```

Each resource has one method per API endpoint. Required fields are required
keyword arguments. Results are read-only model objects. To read a field that
this gem does not know about yet, use `model[:field_name]`.

### API versions

Some parts of the incident.io API have more than one version. `client.<name>`
always uses the newest one. To use an older version, name it:

```ruby
client.catalog.list_types     # v3
client.v2.catalog.list_types  # v2 (deprecated)
```

Calling a deprecated endpoint prints a warning when Ruby's deprecation
warnings are on (`ruby -W:deprecated`).

### Any endpoint

`client.request` calls any endpoint and returns the parsed JSON:

```ruby
client.request(:get, "/v2/incidents/01ABC")
client.paginate("/v2/incidents", items_key: "incidents").first(10)
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

The models and resources in `lib/incident_io/models` and
`lib/incident_io/resources` are generated from the incident.io OpenAPI spec.
Do not edit them by hand. To update them:

```sh
bundle exec rake openapi:fetch  # download the latest spec
bundle exec rake generate       # rebuild the generated code
```

The spec is not stored in git, so run `openapi:fetch` before `generate`.
It is saved to `openapi/openapi.json`, which git ignores.

To rename a generated method, add it to `generator/overrides.yml`.
`bundle exec rake generate:check` fails if the generated code does not match
your local copy of the spec.
