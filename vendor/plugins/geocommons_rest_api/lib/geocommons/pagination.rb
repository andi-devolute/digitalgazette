# Handles pagination aspects of Geocommons::BasePage based on Geocommons::FindMethods
module Geocommons::Pagination
  # get a list of overlays. useful options:
  # * +page+ - number (>= 1), page to use. default: 1
  # * +per_page+ - number (>= 1), results to return per page. default: 10
  # * +query+ - query to send, such as tag:foobar
  def paginate(*args)
    options = args.pop if args.last.kind_of?(Hash)
    options ||= { }
    #query = args.first # NOTE nothing else in here!
    page = options[:page] || 1
    per_page = options[:per_page] || 2

    if options[:query].empty? || options[:query].nil?
      options[:query] = "*"
    end

    # options[:query] = query
    WillPaginate::Collection.create(page, per_page, count(options)) do |pager|
      # @options_from_last_find = nil
      count_options = options.except :page, :per_page, :total_entries, :finder
      find_options = count_options.except(:count).update(:page => page, :limit => pager.per_page)
      results = pack_entries((_find(find_options)))
      pager.replace(results)

      # pager.total_entries = results.size
    end

  end

  def paginate_by_tag(tags, options = {})
    condition = options[:condition] ? options.delete(:condition) : "or"
    query = tags.map { |tag| "tag:#{tag}"}.join(" #{condition} ")
    paginate(options.merge(:query => query))
  end
end
