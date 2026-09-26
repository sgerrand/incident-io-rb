D = Steep::Diagnostic

target :lib do
  signature "sig"

  check "lib"
  # Models are Model.define calls with nothing to check; their types live
  # in sig/incident_io/models. The generated resources index only has
  # memoised accessors, which pass the client as `self`.
  ignore "lib/incident_io/models", "lib/incident_io/resources.rb"

  library "date", "json", "logger", "net-http", "openssl", "securerandom", "time", "uri"

  configure_code_diagnostics(D::Ruby.default)
end

# Typical calls a gem user makes, to check the signatures from the outside.
target :usage do
  signature "sig"

  check "typecheck"

  library "date", "json", "logger", "net-http", "openssl", "securerandom", "time", "uri"

  configure_code_diagnostics(D::Ruby.default)
end
