# incident-io

[![Coverage Status](https://coveralls.io/repos/github/sgerrand/incident-io-rb/badge.svg?branch=main)](https://coveralls.io/github/sgerrand/incident-io-rb?branch=main)

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

### Webhooks

`IncidentIo::Webhook.construct_event` checks a webhook's signature and turns
it into an event. Pass the raw request body, the request headers and your
endpoint's signing secret (it starts with `whsec_`):

```ruby
# In a Rails controller
event = IncidentIo::Webhook.construct_event(
  request.raw_post, request.headers, secret: ENV["INCIDENT_IO_WEBHOOK_SECRET"]
)

case event.type
when "public_incident.incident_created_v2"
  puts event.data.name
when "private_incident.incident_created_v2"
  # Private events only include an ID, so fetch the details.
  incident = client.incidents.show(event.data.id)
end
```

It raises `IncidentIo::Webhook::SignatureError` if the signature is wrong or
the webhook is more than 5 minutes old. `event.id` stays the same when
incident.io retries a webhook, so you can use it to skip duplicates.

### Audit logs

incident.io sends audit logs to a log stream (e.g. Datadog, Splunk or S3),
not through the API. `IncidentIo::AuditLog.parse` turns an entry into a
model:

```ruby
entry = IncidentIo::AuditLog.parse(line)
entry.action      # => "alert_route.created"
entry.actor.name
```

### Types

The gem ships [RBS](https://github.com/ruby/rbs) signatures in `sig/`, so
type checkers such as [Steep](https://github.com/soutaro/steep) know every
resource method, argument and model field.

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
bundle exec rake            # run the specs
COVERAGE=1 bundle exec rake # run the specs and write coverage/index.html
bundle exec rake standard   # lint with Standard (standard:fix to fix)
bundle exec rake typecheck  # type-check with Steep
```

The models and resources in `lib/incident_io/models` and
`lib/incident_io/resources`, and their signatures in `sig/incident_io`, are
generated from the incident.io OpenAPI spec.
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

## Releasing

Releases are automated. Use [Conventional Commits](https://www.conventionalcommits.org/)
(`feat:`, `fix:` and so on) so the version and changelog can be worked out.

1. Each push to `main` updates an open release pull request. It bumps the
   version and adds the new changes to `CHANGELOG.md`.
2. Merging that pull request tags the version and creates a GitHub Release.
3. The release starts the Publish workflow, which pushes the gem to
   RubyGems.org using trusted publishing. No API key is stored in GitHub.

## License

BSD 2-Clause. See [LICENSE](LICENSE).
