# frozen_string_literal: true

module IncidentIo
  # One page of a list endpoint.
  class Page
    include Enumerable

    attr_reader :items, :after, :page_size, :total_record_count, :data

    # `data` is the whole parsed response, for fields other than the items
    # (e.g. `catalog_type` when listing catalog entries).
    def initialize(items:, pagination_meta:, cursor:, data: {}, &fetch_next)
      meta = pagination_meta || {}
      @data = data
      @items = items
      @after = meta["after"]
      @page_size = meta["page_size"]
      @total_record_count = meta["total_record_count"]
      @cursor = cursor
      @fetch_next = fetch_next
    end

    def each(&)
      items.each(&)
    end

    # False on the last page. Also false if the API sends back the cursor we
    # just used, so a bad response can't loop forever.
    def next_page?
      !after.nil? && !after.to_s.empty? && items.any? && after != @cursor
    end

    def next_page
      next_page? ? @fetch_next.call(after) : nil
    end
  end

  # Walks every item of a cursor-paginated list endpoint, fetching pages
  # only as they are needed:
  #
  #   client.paginate("/v2/incidents", items_key: "incidents").each { |i| ... }
  #   client.paginate(...).first(10)        # fetches only enough pages for 10
  #   client.paginate(...).each_page { |page| page.total_record_count }
  class Pager
    include Enumerable

    def initialize(client, path, items_key:, query: {}, model: nil, request_options: {})
      @client = client
      @path = path
      @items_key = items_key
      @query = query || {}
      @model = model
      @request_options = request_options
    end

    def first_page
      fetch(@query[:after] || @query["after"])
    end

    def each_page
      return enum_for(:each_page) unless block_given?

      page = first_page
      while page
        yield page
        page = page.next_page
      end
    end

    def each(&block)
      return enum_for(:each) unless block

      each_page { |page| page.each(&block) }
    end
    alias auto_paging_each each

    private

    def fetch(cursor)
      query = @query.reject { |k, _| k.to_s == "after" }
      query[:after] = cursor if cursor

      data = @client.request(:get, @path, query: query, request_options: @request_options) || {}
      items = Array(data[@items_key])
      items = items.map { |item| @model.from_api(item) } if @model

      Page.new(items: items, pagination_meta: data["pagination_meta"], cursor: cursor, data: data) { |after| fetch(after) }
    end
  end
end
