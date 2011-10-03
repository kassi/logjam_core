require 'amqp'
require 'yajl'
require 'set'

module Logjam

  class MongoImportBuffer

    attr_reader :iso_date_string

    def initialize(dbname, app, env, iso_date_string)
      @app = app
      @env = env
      @iso_date_string = iso_date_string

      database  = Logjam.mongo.db(dbname)
      @totals   = Totals.ensure_indexes(database["totals"])
      @minutes  = Minutes.ensure_indexes(database["minutes"])
      @quants   = Quants.ensure_indexes(database["quants"])
      @requests = Requests.ensure_indexes(database["requests"])

      #     @hours = db["hours"]
      #     @hours.create_index([ ["page", Mongo::ASCENDING], ["hour", Mongo::ASCENDING] ])

      @import_threshold  = Logjam.import_threshold
      @generic_fields    = Set.new(Requests::GENERIC_FIELDS - %w(page response_code) + %w(action code engine))
      @quantified_fields = Requests::QUANTIFIED_FIELDS
      @squared_fields    = Requests::FIELDS.map{|f| [f,"#{f}_sq"]}
      @other_time_resources = Resource.time_resources - %w(total_time gc_time)

      setup_buffers
    end

    def add(entry)
      page = entry["page"] = (entry.delete("action") || "Unknown")
      page << "#unknown_method" unless page =~ /#/
      pmodule = "::"
      if page =~ /^(.+?)::/ || page =~ /^([^:#]+)#/
        pmodule << $1
        @modules << pmodule
      end

      response_code = entry["response_code"] = (entry.delete("code") || 500)
      total_time    = (entry["total_time"] ||= 1.0)
      started_at    = entry["started_at"]
      lines         = (entry["lines"] ||= [])
      severity      = (entry["severity"] ||= lines.map{|s,t,l| s}.max || 5)

      # mongo field names must not contain dots
      if exceptions = entry["exceptions"]
        exceptions.each{|e| e.gsub!('.','_')}
      end

      add_allocated_memory(entry)
      add_other_time(entry, total_time)
      minute = add_minute(entry)

      increments = {"count" => 1}
      add_squared_fields(increments, entry)

      if total_time >= 2000 || response_code == 500 then
        increments["apdex.frustrated"] = 1
      elsif total_time < 100 then
        increments["apdex.happy"] = increments["apdex.satisfied"] = 1
      elsif total_time < 500 then
        increments["apdex.satisfied"] = 1
      elsif total_time < 2000 then
        increments["apdex.tolerating"] = 1
      end

      increments["response.#{response_code}"] = 1

      # only store severities which indicate warnings/errors
      increments["severity.#{severity}"] = 1 if severity > 1

      exceptions.each do |e|
        increments["exceptions.#{e}"] = 1
      end if exceptions

      add_minutes_and_totals(increments, page, pmodule, minute)

      #     hour = minute / 60
      #     [page, "all_pages", pmodule].each do |p|
      #       increments.each do |f,v|
      #         (@hours_buffer[[p,hour]] ||= Hash.new(0))[f] += v
      #       end
      #     end

      add_quants(increments, page)

      if interesting?(entry)
        begin
          request_id = @requests.insert(entry)
        rescue Exception
          $stderr.puts "Could not insert document: #{$!}"
        end
      end

      if severity > 1
        # extract the first error found (duplicated code from logjam helpers)
        description = ((lines.detect{|(s,t,l)| s >= 2})[2].to_s)[0..80] rescue "--- unknown ---"
        error_info = { "request_id" => request_id.to_s,
                       "severity" => severity, "action" => page,
                       "description" => description, "time" => started_at }
        ["all_pages", pmodule].each do |p|
          (@errors_buffer[p] ||= []) << error_info
        end
      end

    end

    def flush
      publish_totals
      publish_errors
      flush_totals_buffer
      flush_minutes_buffer
      # flush_hours_buffer
      flush_quants_buffer
    end

    private

    def add_other_time(entry, total_time)
      ot = total_time.to_f
      @other_time_resources.each {|r| (v = entry[r]) && (ot -= v)}
      entry["other_time"] = ot
    end

    def extract_minute(iso_string)
      60 * iso_string[11..12].to_i + iso_string[14..15].to_i
    end

    def add_allocated_memory(entry)
      if !(allocated_memory = entry["allocated_memory"]) && (allocated_objects = entry["allocated_objects"])
        # assume 64bit ruby
        entry["allocated_memory"] = entry["allocated_bytes"].to_i + allocated_objects * 40
      end
    end

    def add_minute(entry)
      entry["minute"] = extract_minute(entry["started_at"])
    end

    def add_squared_fields(increments, entry)
      @squared_fields.each do |f,fsq|
        next if (v = entry[f]).nil?
        if v == 0
          entry.delete(f)
        else
          increments[f] = (v = v.to_f)
          increments[fsq] = v*v
        end
      end
    end

    def add_minutes_and_totals(increments, page, pmodule, minute)
      [page, "all_pages", pmodule].each do |p|
        mbuffer = (@minutes_buffer[[p,minute]] ||= Hash.new(0.0))
        tbuffer = (@totals_buffer[p] ||= Hash.new(0.0))
        increments.each do |f,v|
          mbuffer[f] += v
          tbuffer[f] += v
        end
      end
    end

    def add_quants(increments, page)
      @quantified_fields.each do |f|
        next unless x=increments[f]
        if f == "allocated_objects"
          kind = "m"
          d = 10000
        elsif f == "allocated_bytes"
          kind = "m"
          d = 100000
        else
          kind = "t"
          d = 100
        end
        x = ((x.floor/d).ceil+1)*d
        [page, "all_pages"].each do |p|
          (@quants_buffer[[p,kind,x]] ||= Hash.new(0.0))[f] += 1
        end
      end
    end

    def interesting?(request)
      request["total_time"].to_f > @import_threshold ||
        request["severity"] > 1 ||
        request["response_code"].to_i >= 400 ||
        request["exceptions"] ||
        request["heap_growth"].to_i > 0
    end

    def setup_buffers
      @quants_buffer = {}
      @totals_buffer = {}
      @minutes_buffer = {}
      # @hours_buffer = {}
      @errors_buffer = {}
      @modules = Set.new(%w(all_pages))
    end

    UPSERT_ONE = {:upsert => true, :multi => false}

    def flush_quants_buffer
      @quants_buffer.each do |(p,k,q),inc|
        @quants.update({"page" => p, "kind" => k, "quant" => q}, { '$inc' => inc }, UPSERT_ONE)
      end
      @quants_buffer.clear
    end

    def flush_minutes_buffer
      @minutes_buffer.each do |(p,m),inc|
        @minutes.update({"page" => p, "minute" => m}, { '$inc' => inc }, UPSERT_ONE)
      end
      @minutes_buffer.clear
    end

    #   def flush_hours_buffer
    #     @hours_buffer.each do |(p,h),inc|
    #       @hours.update({"page" => p, "hour" => h}, { '$inc' => inc }, UPSERT_ONE)
    #     end
    #     @hours_buffer.clear
    #   end

    def flush_totals_buffer
      @totals_buffer.each do |(p,inc)|
        @totals.update({"page" => p}, { '$inc' => inc }, UPSERT_ONE)
      end
      @totals_buffer.clear
    end

    def self.exchange(app, env)
      (@exchange||={})["#{app}-#{env}"] ||=
        begin
          channel = AMQP::Channel.new(AMQP.connect(:host => live_stream_host))
          channel.auto_recovery = true
          channel.topic("logjam-performance-data-#{app}-#{env}")
        end
    end

    def self.live_stream_host
      @live_stream_host ||= Logjam.streams["livestream-#{Rails.env}"].host
    end

    def exchange
      @exchange ||= self.class.exchange(@app, @env)
    end

    NO_REQUEST = {"count" => 0}

    def publish_totals
      # always publish something every second to the perf data exchange
      @modules.each { |p| publish(p, @totals_buffer[p] || NO_REQUEST) }
    end

    def publish_errors
      @modules.each do |p|
        if errs = @errors_buffer[p]
          # $stderr.puts errs
          publish(p, errs)
        end
      end
      @errors_buffer.clear
    end

    def publish(p, inc)
      exchange.publish(Yajl::Encoder.encode(inc), :key => p.sub(/^::/,'').downcase)
    rescue
      $stderr.puts "could not publish performance/error data: #{$!}"
    end
  end
end
