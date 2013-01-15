require 'erb'
require 'mongo'
require 'central_logger/replica_set_helper'

module CentralLogger
  class MongoLogger < ActiveSupport::BufferedLogger
    include ReplicaSetHelper

    MB = 2 ** 20
    PRODUCTION_COLLECTION_SIZE = 256 * MB
    DEFAULT_COLLECTION_SIZE = 128 * MB
    # Looks for configuration files in this order
    CONFIGURATION_FILES = ["central_logger.yml", "mongoid.yml", "database.yml"]
    LOG_LEVEL_SYM = [:debug, :info, :warn, :error, :fatal, :unknown]

    attr_reader :db_configuration, :mongo_connection, :mongo_collection_name, :mongo_collection

    def initialize(options={})
      path = options[:path] || File.join(Rails.root, "log/#{Rails.env}.log")
      level = options[:level] || DEBUG
      internal_initialize
      if disable_file_logging?
        @level = level
        @buffer        = {}
        @auto_flushing = 1
        @guard = Mutex.new
      else
        super(path, level)
      end
    rescue => e
      # should use a config block for this
      Rails.env.production? ? (raise e) : (puts "Using BufferedLogger due to exception: " + e.message)
    end

    def add_metadata(options={})
      options.each_pair do |key, value|
        unless [:messages, :request_time, :ip, :runtime, :application_name].include?(key.to_sym)
          @mongo_record[key] = value
        else
          raise ArgumentError, ":#{key} is a reserved key for the central logger. Please choose a different key"
        end
      end
    end

    def add(severity, message = nil, progname = nil, &block)
      if @level <= severity && message.present? && @mongo_record.present?
        # do not modify the original message used by the buffered logger
        msg = logging_colorized? ? message.to_s.gsub(/(\e(\[([\d;]*[mz]?))?)?/, '').strip : message
        @mongo_record[:messages][LOG_LEVEL_SYM[severity]] << msg
      end
      # may modify the original message
      disable_file_logging? ? message : super
    end

    # Drop the capped_collection and recreate it
    def reset_collection
      @mongo_collection.drop
      create_collection
    end

    def mongoize(options={})
      @mongo_record = options.merge({
        :messages => Hash.new { |hash, key| hash[key] = Array.new },
        :request_time => Time.now.getutc,
        :application_name => @application_name
      })

      runtime = Benchmark.measure{ yield }.real if block_given?
    rescue Exception => e
      add(3, e.message + "\n" + e.backtrace.join("\n"))
      # Reraise the exception for anyone else who cares
      raise e
    ensure
      # In case of exception, make sure runtime is set
      @mongo_record[:runtime] = ((runtime ||= 0) * 1000).ceil
      begin
        @insert_block.call
      rescue
        # do extra work to inpect (and flatten)
        force_serialize @mongo_record
        @insert_block.call rescue nil
      end
    end

    def authenticated?
      @authenticated
    end

    private
      # facilitate testing
      def internal_initialize
        configure
        connect
        check_for_collection
      end

      def disable_file_logging?
        @db_configuration.fetch('disable_file_logging', false)
      end

      def configure
        default_capsize = Rails.env.production? ? PRODUCTION_COLLECTION_SIZE : DEFAULT_COLLECTION_SIZE
        @mongo_collection_name = "#{Rails.env}_log"
        @authenticated = false
        @db_configuration = {
          'host' => 'localhost',
          'port' => 27017,
          'capsize' => default_capsize}.merge(resolve_config)
        @application_name = resolve_application_name
        @safe_insert = @db_configuration['safe_insert'] || false

        @insert_block = @db_configuration.has_key?('replica_set') && @db_configuration['replica_set'] ?
          lambda { rescue_connection_failure{ insert_log_record(@safe_insert) } } :
          lambda { insert_log_record }
      end

      def resolve_application_name
        if @db_configuration.has_key?('application_name')
          @db_configuration['application_name']
        elsif Rails::VERSION::MAJOR >= 3
          Rails.application.class.to_s.split("::").first
        else
          # rails 2 requires detective work if it's been deployed by capistrano
          # if last entry is a timestamp, go back 2 dirs (ex. /app_name/releases/20110304132847)
          path = Rails.root.to_s.split('/')
          path.length >= 4 && path.last =~ /^\d/ ? path.last(3)[0] : path.last
        end
      end

      def resolve_config
        config = {}
        CONFIGURATION_FILES.each do |filename|
          config_file = Rails.root.join("config", filename)
          if config_file.file?
            config = YAML.load(ERB.new(config_file.read).result)[Rails.env]
            config = config['mongo'] if config.has_key?('mongo')
            break
          end
        end
        config
      end

      def connect
        if @db_configuration['slaves'] == nil
           @mongo_connection = Mongo::ReplSetConnection.new([@db_configuration['host'], @db_configuration['port']], 
                                                          :read_secondary => true).db(@db_configuration['database'])
        else
           @mongo_connection = Mongo::ReplSetConnection.new([@db_configuration['host'], @db_configuration['port']], 
                                                          [@db_configuration['slaves'][0]["host"], @db_configuration['slaves'][0]["port"]], :read_secondary => true).db(@db_configuration['database'])             
        end

        if @db_configuration['username'] && @db_configuration['password']
          # the driver stores credentials in case reconnection is required
          @authenticated = @mongo_connection.authenticate(@db_configuration['username'],
                                                          @db_configuration['password'])
        end
      end

      def create_collection
        @mongo_connection.create_collection(@mongo_collection_name,
                                            {:capped => true, :size => @db_configuration['capsize'].to_i})
      end

      def check_for_collection
        # setup the capped collection if it doesn't already exist
        unless @mongo_connection.collection_names.include?(@mongo_collection_name)
          create_collection
        end
        @mongo_collection = @mongo_connection[@mongo_collection_name]
      end

      def insert_log_record(safe=false)
        @mongo_collection.insert(@mongo_record, :safe => safe)
      end

      def logging_colorized?
        # Cache it since these ActiveRecord attributes are assigned after logger initialization occurs in Rails boot
        @colorized ||= Object.const_defined?(:ActiveRecord) &&
        (Rails::VERSION::MAJOR >= 3 ?
          ActiveRecord::LogSubscriber.colorize_logging :
          ActiveRecord::Base.colorize_logging)
      end

      # force the data in the db by inspecting each top level array and hash element
      # this will flatten other hashes and arrays
      def force_serialize(rec)
        if msgs = rec[:messages]
          LOG_LEVEL_SYM.each do |i|
            msgs[i].collect! { |j| j.inspect } if msgs[i]
          end
        end
        if pms = rec[:params]
          pms.each { |i, j| pms[i] = j.inspect }
        end
      end
  end # class MongoLogger
end
