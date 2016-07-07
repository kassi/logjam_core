module Logjam

  class FilteredDataset
    HEAP_SLOT_SIZE = 40

    attr_accessor :interval, :page, :response_code,
    :plot_kind, :resource, :grouping, :grouping_function,
    :start_minute, :end_minute, :date, :limit, :offset

    DEFAULTS = {:plot_kind => :time, :interval => '5', :section => 'backend',
      :grouping => 'page', :resource => 'total_time', :grouping_function => 'sum',
      :start_minute => '0', :end_minute => '1440', :page => '',
      :time_range => 'date', :auto_refresh => '0'}

    def self.is_default?(attribute, value)
      DEFAULTS.keys.include?(attribute.to_sym) && DEFAULTS[attribute.to_sym].to_s == value
    end

    def self.clean_url_params(params, old_params)
      default_app = params.delete(:default_app) || Logjam.default_app
      params = params.reject{|k,v| old_params[k] == v && (v.blank? || is_default?(k, v)) }
      if app = params[:app]
        params.delete(:app) if app == default_app
        if env = params[:env]
          if default_env = params.delete(:default_env)
            params.delete(:env) if env == default_env
          else
            params.delete(:env) if env == Logjam.default_env(app)
          end
        end
      end
      params
    end

    def initialize(options = {})
      # puts options.inspect
      @date = options[:date]
      @app = options[:app]
      @env = options[:env]
      @db = Logjam.db(@date, @app, @env)
      @interval = (options[:interval] || DEFAULTS[:interval]).to_i
      @page = options[:page].to_s
      @response_code = options[:response_code] if options[:response_code].present?
      @plot_kind = options[:plot_kind] || DEFAULTS[:plot_kind]
      @resource = options[:resource] || DEFAULTS[:resource]
      @grouping = options[:grouping]
      @grouping_function = options[:grouping_function] || DEFAULTS[:grouping_function]
      @start_minute = (options[:start_minute] || DEFAULTS[:start_minute]).to_i
      @end_minute = (options[:end_minute] || DEFAULTS[:end_minute]).to_i
      @collected_resources = options[:collected_resources]
      @limit = options[:limit] || (@grouping == "request" ? 12 : 12)
      @offset = options[:offset] || 0
      @request_counts = {}
      @count = {}
      @query_result = {}
      @plot_data = {}
    end

    def grouping_name
      if grouping == "page"
        if namespaces?
          "namespace"
        else
          "action"
        end
      else
        grouping
      end
    end

    def page_description
      page == "::" ? "all actions" : page
    end

    def description
      Resource.description(resource, grouping, grouping_function)
    end

    def short_description
      Resource.short_description(resource, grouping, grouping_function)
    end

    def grouping?
      Resource.grouping?(grouping)
    end

    def hash
      Digest::MD5.hexdigest "#{date} #{interval} #{user_id} #{host} #{page} #{response_code} #{plot_kind} #{start_minute} #{end_minute}"
    end

    def accumulates_time?
      [:time, :frontend].include?(Resource.resource_type(resource)) &&
        grouping? &&
        [:sum, :avg, :stddev, :count, :apdex, :fapdex, :papdex, :xapdex].include?(grouping_function.to_sym)
    end

    def intervals_per_day
      24 * 60 / interval
    end

    def intervals_per_hour
      60 / interval
    end

    def live_stream?
      (@date == Date.today || Rails.env.development?) && (page.blank? || page == "all_pages" || page == "::" || namespace?)
    end

    def empty?(resource = 'total_time')
      count_requests(resource) == 0
    end

    def count_requests(section = :backend)
      @request_counts[section] ||= totals.count(section).to_i
    end

    def count(section = :backend)
      @count[section] ||= totals.request_count(section)
    end

    def sum(time_attr = 'total_time')
      totals.sum(time_attr)
    end

    def single_page?
      totals.the_pages.size == 1
    end

    def size(section = :backend)
      do_the_query(section).size
    end

    def requests
      @requests ||=
        begin
          query_opts = {start_minute: @start_minute, end_minute: @end_minute, skip: @offset, limit: @limit}
          Requests.new(@db, resource, page, query_opts).all
        end
    end

    def do_the_query(section = :backend, options = {})
      options = {:grouping => self.grouping, :resource => self.resource}.merge!(options)
      grouping = options[:grouping]
      resource = options[:resource]
      @query_result[[section, grouping, resource]] ||=
        if grouping == "request"
          requests
        else
          if grouping_function.to_sym == :count
            sort_by = "count"
          elsif grouping_function.to_sym == :apdex
            sort_by = "apdex"
          else
            sort_by = "#{resource}_#{grouping_function}"
          end
          totals.pages(:order => sort_by, :limit => limit, :section => section, :resource =>resource)
        end
    end

    def resource_fields
      case Resource.resource_type(resource)
      when :time       then Resource.time_resources
      when :call       then Resource.call_resources
      when :memory     then Resource.memory_resources
      when :heap       then Resource.heap_resources
      when :dom        then Resource.dom_resources
      when :frontend   then Resource.frontend_resources
      end & @collected_resources
    end

    def totals
      @totals ||= Totals.new(@db, %w(apdex fapdex papdex xapdex response severity exceptions js_exceptions) + resource_fields, page)
    end

    def namespace?
      totals.page_names.include?("::#{page.sub(/\A::/,'')}")
    end

    def namespaces?(section = :backend)
      totals.page_names.any?{|pn| pn =~ /\A::/}
      # TODO: this breaks apdex sorting. why?
      #pages = do_the_query(:backend, :grouping => "action")
      #pages.all?{|p| p.page == 'Others...' || p.page =~ /\A::/}
    end

    def action?
      totals.page_names.include?(page)
    end

    def top_level?
      ['', 'all_pages', '::'].include?(page)
    end

    def summary
      @summary ||=
        begin
          all_resources = Resource.time_resources + Resource.call_resources + Resource.memory_resources + Resource.heap_resources + Resource.frontend_resources + Resource.dom_resources
          resources = (all_resources & @collected_resources) - %w(heap_growth) + %w(apdex fapdex papdex xapdex response callers)
          Totals.new(@db, resources, page, totals.page_names)
        end
    end

    def measures_bytes?(attr)
      [:allocated_memory, :allocated_bytes].include? attr.to_sym
    end

    YLABELS = {
      :time => 'Response time (ms)', :call => '# of calls',
      :memory => 'Allocations (bytes)', :heap => 'Heap size (slots)',
      :frontend => 'Frontend time (ms)', :dom => '# of nodes'
    }

    def has_callers?
      summary.callers_count > 0
    end

    def has_frontend?
      summary.request_count(:frontend) > 0
    end

    def ylabel
      YLABELS[plot_kind] || ""
    end

    RESOURCES_EXCLUDED_FROM_PLOT = %w(total_time allocated_memory requests heap_growth page_time frontend_time)
    LINE_PLOTTED_RESOURCES = %w(ajax_time gc_time dom_interactive)

    def plotted_resources
      (Resource.resources_for_type(plot_kind) & @collected_resources) - RESOURCES_EXCLUDED_FROM_PLOT
    end

    def plot_data(section)
      @plot_data[section] ||=
        begin
          resources = plotted_resources
          events = Events.new(@db).events
          mins = Minutes.new(@db, resources, page, totals.page_names, interval)
          minutes = mins.minutes
          counts = section == :frontend ? mins.counts["frontend_count"] : mins.counts["count"]
          max_total = 0
          plot_resources = resources.clone
          LINE_PLOTTED_RESOURCES.each do |r|
            plot_resources += [r] if plot_resources.delete(r)
          end
          plot_resources.unshift("free_slots") if plot_resources.delete("heap_size")
          zero = Hash.new(0.0)
          results = plot_resources.inject({}){|h,r| h[r] = {}; h}
          totals = []
          nonzero = 0
          intervals_per_day.times do |i|
            row = minutes[i] || zero
            total = 0
            if (heap_size = row["heap_size"]) && (live_data_set_size = row["live_data_set_size"]) && (live_data_set_size > heap_size)
              row["live_data_set_size"] = row["heap_size"]
            end
            plot_resources.each do |r|
              v = r == "free_slots" ? row["heap_size"] - row["live_data_set_size"] : row[r]
              if v.is_a?(Float) && v.nan?
                Rails.logger.error("found NaN for resource #{r} minute #{i}")
                v = 0.0
              else
                # Rails.logger.error("found #{v} for resource #{r} minute #{i}")
              end
              total += v unless LINE_PLOTTED_RESOURCES.include?(r)
              results[r][i] = v
            end
            if total == 0 && section == :frontend && (ajax_time = row["ajax_time"])
              total = ajax_time.to_f
            end
            totals << total if total > 0
            max_total = total if max_total < total
            nonzero += 1 if total > 0
          end
          plot_data = data_for_proto_vis(results, plot_resources).reverse
          lines = {}
          LINE_PLOTTED_RESOURCES.reverse.each do |r|
            lines[r] = plot_data.shift if resources.include?(r)
          end
          request_counts = []
          intervals_per_day.times{|i| request_counts << (counts[i] || 0) / 60.0}
          y_zoom = totals.sort[(totals.size*0.9).to_i].to_f
          [plot_resources-LINE_PLOTTED_RESOURCES, plot_data, events, max_total, request_counts, lines, y_zoom]
        end
    end

    def data_for_proto_vis(results, resources)
      data = resources.map{[]}
      resources.each_with_index do |r,j|
        resource_data = data[j]
        resource_hash = results[r]
        intervals_per_day.times{|i| resource_data << [i, resource_hash[i]] }
      end
      data
    end

    def has_distribution_plot?
      [:time, :memory, :frontend].include?(plot_kind)
    end

    def get_data_for_distribution_plot(what_to_plot)
      case what_to_plot
      when :request_time
        resources = Resource.time_resources
        kind = "t"
      when :frontend_time
        resources = Resource.frontend_resources - %w(frontend_time)
        kind = "f"
      when :allocated_objects
        resources = %w(allocated_objects)
        kind = "m"
      when :allocated_bytes
        resources = %w(allocated_bytes)
        kind = "m"
      end
      @the_quants = Quants.new(@db, resources, page, kind)
    end

    def histogram_data(resource)
      quantized = @the_quants.quants(resource)
      points = []
      quantized.keys.sort.each{|x| points << [x, quantized[x]] } unless quantized.blank?
      count = points.map(&:second).sum
      return {} if count == 0
      c90 = count * 0.90
      c95 = count * 0.95
      c99 = count * 0.99
      n = i = 0
      l = points.size
      while n < c90 && i < l
        n += points[i][1]
        i += 1
      end
      p90 = points[i-1][0]
      while n < c95 && i < l
        n += points[i][1]
        i += 1
      end
      p95 = points[i-1][0]
      while n < c99 && i < l
        n += points[i][1]
        i += 1
      end
      p99 = points[i-1][0]
      {points: points, p90: p90, p95: p95, p99: p99}
    end

    def happy_count(section = :backend)
      totals.apdex(section)["happy"].to_i
    end

    def happy(section = :backend)
      happy_count(section) / totals.count(section).to_f
    end

    def satisfied_count(section = :backend)
      totals.apdex(section)["satisfied"].to_i
    end

    def satisfied(section = :backend)
      satisfied_count(section) / totals.count(section).to_f
    end

    def tolerating_count(section = :backend)
      totals.apdex(section)["tolerating"].to_i
    end

    def tolerating(section = :backend)
      tolerating_count(section) / totals.count(section).to_f
    end

    def frustrated_count(section = :backend)
      totals.apdex(section)["frustrated"].to_i
    end

    def frustrated(section = :backend)
      frustrated_count(section) / totals.count(section).to_f
    end

    def apdex(section = :backend)
      satisfied(section) + tolerating(section) / 2.0
    end

    def error_count
      response_codes[500] || 0
    end

    def severities
      totals.severities
    end

    def logged_error_count(level)
      severities[level] || 0
    end

    def logged_error_count_above(level)
      (level..5).to_a.map{|l| logged_error_count(l) }.sum
    end

    def exceptions
      totals.exceptions
    end

    def exception_count
      totals.exception_count
    end

    def js_exception_count
      totals.js_exception_count
    end

    def response_codes
      totals.response_codes
    end

    def response_codes_above(response_code)
      response_codes.select{|k,v| k.to_i >= response_code}.values.sum
    end

    def empty_response_code_summy
      Hash.new(0).merge!("1xx" => 0, "2xx" => 0, "3xx" => 0, "4xx" => 0, "5xx" => 0)
    end

    def response_code_summary
      @response_code_summary ||=
        response_codes.each_with_object(empty_response_code_summy) do |(rc,c),s|
          rc_s = rc > 999 ? "?xx" : sprintf("%03d", rc).first + "xx"
          s[rc_s] += c
        end
    end
  end
end
