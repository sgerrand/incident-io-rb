# frozen_string_literal: true

require_relative "../../generator/incident_io_generator"

module GeneratorHelpers
  # A small spec covering the shapes the generator handles.
  def mini_spec
    {
      "tags" => [{ "name" => "Widgets V2", "description" => "Manage widgets." }],
      "components" => {
        "schemas" => {
          "WidgetV2" => {
            "type" => "object",
            "description" => "A widget.",
            "required" => ["id"],
            "properties" => {
              "id" => { "type" => "string", "description" => "Unique ID" },
              "class" => { "type" => "string" },
              "created_at" => { "type" => "string", "format" => "date-time" },
              "parts" => { "type" => "array", "items" => { "$ref" => "#/components/schemas/PartV2" } },
              "labels" => { "type" => "object", "additionalProperties" => { "type" => "string" } },
              "kind" => { "type" => "string", "enum" => %w[big small] }
            }
          },
          "PartV2" => { "type" => "object", "properties" => { "id" => { "type" => "string" } } },
          "PaginationMetaResultV2" => {
            "type" => "object",
            "properties" => { "after" => { "type" => "string" }, "page_size" => { "type" => "integer" } }
          },
          "WidgetsListResultV2" => {
            "type" => "object",
            "properties" => {
              "widgets" => { "type" => "array", "items" => { "$ref" => "#/components/schemas/WidgetV2" } },
              "pagination_meta" => { "$ref" => "#/components/schemas/PaginationMetaResultV2" }
            }
          },
          "WidgetsShowResultV2" => {
            "type" => "object",
            "properties" => { "widget" => { "$ref" => "#/components/schemas/WidgetV2" } }
          },
          "WidgetsCreatePayloadV2" => {
            "type" => "object",
            "required" => %w[name idempotency_key],
            "properties" => {
              "name" => { "type" => "string", "description" => "Widget name" },
              "idempotency_key" => { "type" => "string" },
              "part" => { "$ref" => "#/components/schemas/PartV2" }
            }
          }
        }
      },
      "paths" => {
        "/v2/widgets" => {
          "get" => operation("Widgets V2#List", "WidgetsListResultV2", parameters: [
            { "in" => "query", "name" => "page_size", "schema" => { "type" => "integer" } },
            { "in" => "query", "name" => "after", "schema" => { "type" => "string" } },
            { "in" => "query", "name" => "kind", "required" => true, "style" => "deepObject",
              "schema" => { "type" => "object" } }
          ]),
          "post" => operation("Widgets V2#Create", "WidgetsShowResultV2", code: "201", body: "WidgetsCreatePayloadV2")
        },
        "/v2/widgets/{id}" => {
          "get" => operation("Widgets V2#Show", "WidgetsShowResultV2", parameters: [path_param("id")]),
          "delete" => operation("Widgets V2#Destroy", nil, code: "204", parameters: [path_param("id")], deprecated: true)
        },
        "/v2/widgets/{id}/export" => {
          "get" => operation("Widgets V2#Export", nil, parameters: [path_param("id")], content_type: "text/csv")
        }
      }
    }
  end

  def operation(id, result, code: "200", parameters: [], body: nil, deprecated: false, content_type: nil)
    response = { "description" => "OK" }
    response["content"] = { "application/json" => { "schema" => { "$ref" => "#/components/schemas/#{result}" } } } if result
    response["content"] = { content_type => { "schema" => { "type" => "string" } } } if content_type

    op = {
      "operationId" => id,
      "tags" => [id.split("#").first],
      "description" => "Does #{id}.",
      "x-rbac-scopes" => ["widgets.read"],
      "parameters" => parameters,
      "responses" => { code => response, "400" => { "description" => "Bad" } }
    }
    op["requestBody"] = { "content" => { "application/json" => { "schema" => { "$ref" => "#/components/schemas/#{body}" } } } } if body
    op["deprecated"] = true if deprecated
    op
  end

  def path_param(name)
    { "in" => "path", "name" => name, "required" => true, "schema" => { "type" => "string" } }
  end
end

RSpec.configure { |c| c.include GeneratorHelpers, :generator }
