# frozen_string_literal: true

module IncidentIo
  # One page of a list endpoint.
  class Page
    include Enumerable

    # The page's items, as models or raw hashes
    #
    # @return [Array]
    attr_reader :items

    # The cursor for the next page
    #
    # @return [String, nil]
    attr_reader :after

    # How many items the API put on each page
    #
    # @return [Integer, nil]
    attr_reader :page_size

    # How many items there are in total, for endpoints that say
    #
    # @return [Integer, nil]
    attr_reader :total_record_count

    # The whole parsed response
    #
    # Useful for fields other than the items, e.g. `catalog_type` when
    # listing catalog entries.
    #
    # @return [Hash]
    attr_reader :data

    # Creates a page from a list response
    #
    # @param items [Array]
    # @param pagination_meta [Hash, nil]
    # @param cursor [String, nil] the cursor this page was fetched with
    # @param data [Hash] the whole parsed response
    # @yieldparam after [String] cursor for the next page
    # @yieldreturn [Page] the next page
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

    # Yields each item on this page
    #
    # @yieldparam item [Object]
    # @return [Array, Enumerator] an Enumerator without a block
    def each(&block)
      return items.each unless block

      items.each(&block)
    end

    # Whether there's another page
    #
    # False on the last page. Also false if the API sends back the cursor we
    # just used, so a bad response can't loop forever.
    #
    # @return [Boolean]
    def next_page?
      !after.to_s.empty? && items.any? && after != @cursor
    end

    # Fetches the next page
    #
    # @return [Page, nil] nil on the last page
    def next_page
      cursor = after
      return nil if cursor.nil? || !next_page?

      @fetch_next.call(cursor)
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

    # Creates a pager; nothing is fetched until it's used
    #
    # @param client [Client]
    # @param path [String]
    # @param items_key [String] key of the item array in the response
    # @param query [Hash, nil] query parameters; `after` sets the first cursor
    # @param model [#from_api, nil] builds each item; raw hashes when nil
    # @param request_options [Hash] see Client#request
    def initialize(client, path, items_key:, query: nil, model: nil, request_options: {})
      @client = client
      @path = path
      @items_key = items_key
      @query = query || {}
      @model = model
      @request_options = request_options
    end

    # Fetches the first page
    #
    # @return [Page]
    def first_page
      fetch(@query[:after] || @query["after"])
    end

    # Yields each page, fetching the next one only when needed
    #
    # @yieldparam page [Page]
    # @return [void, Enumerator] an Enumerator without a block
    def each_page
      return enum_for(:each_page) unless block_given?

      page = first_page
      while page
        yield page
        page = page.next_page
      end
    end

    # Yields every item of every page, fetching pages as needed
    #
    # @yieldparam item [Object]
    # @return [void, Enumerator] an Enumerator without a block
    def each(&block)
      return enum_for(:each) unless block

      each_page { |page| page.each(&block) }
    end

    # Same as #each
    #
    # @yieldparam item [Object]
    # @return [void, Enumerator] an Enumerator without a block
    def auto_paging_each(&block)
      block ? each(&block) : each
    end

    private

    # Fetches one page
    #
    # @param cursor [String, nil] nil for the first page
    # @return [Page]
    def fetch(cursor)
      query = @query.reject { |k, _| k.to_s == "after" }
      query[:after] = cursor if cursor

      data = @client.request(:get, @path, query: query, request_options: @request_options) || {}
      items = Array(data[@items_key])
      model = @model
      items = items.map { |item| model.from_api(item) } if model

      Page.new(items: items, pagination_meta: data["pagination_meta"], cursor: cursor, data: data) { |after| fetch(after) }
    end
  end
end
