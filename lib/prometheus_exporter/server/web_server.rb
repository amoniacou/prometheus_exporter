# frozen_string_literal: true

require "rack"
require "rackup"
require "timeout"
require "zlib"
require "stringio"
require "logger"

require_relative "web_app"

module PrometheusExporter::Server
  class WebServer
    attr_reader :collector

    def initialize(opts)
      @port = opts[:port] || PrometheusExporter::DEFAULT_PORT
      @bind = opts[:bind] || PrometheusExporter::DEFAULT_BIND_ADDRESS
      @verbose = opts[:verbose] || false
      @auth = opts[:auth]
      @realm = opts[:realm] || PrometheusExporter::DEFAULT_REALM

      log_target = opts[:log_target]
      if @verbose
        @logger = Logger.new(log_target || $stderr)
      else
        @logger = Logger.new(log_target || File::NULL)
      end

      @logger.info "Using Basic Authentication via #{@auth}" if @verbose && @auth

      if %w[ALL ANY].include?(@bind)
        @logger.info "Listening on both 0.0.0.0/:: network interfaces"
        @bind = "0.0.0.0"
      end

      @collector = opts[:collector] || Collector.new(logger: @logger)

      @handler = opts[:handler]

      @tls_cert_file = opts[:tls_cert_file]
      @tls_key_file = opts[:tls_key_file]
    end

    def start
      @runner ||= Thread.start do
        handler = @handler ? Rackup::Handler.get(@handler) : Rackup::Handler.default

        unless handler
          raise "No Rackup handler found. Please install a server like 'puma' or 'falcon'."
        end

        options = {
          Port: @port,
          Host: @bind,
          Verbose: @verbose,
          Logger: @logger,
          AccessLog: []
        }

        if @tls_cert_file && @tls_key_file
          @logger.info "TLS enabled"
          if handler.name =~ /Puma/ || handler.name =~ /Falcon/
            # Puma specific SSL configuration via URL
            options[:Host] = "ssl://#{@bind}:#{@port}?key=#{@tls_key_file}&cert=#{@tls_cert_file}"
          else
            # Fallback for others, though might not work
            options[:SSLEnable] = true
            options[:SSLCertificate] = @tls_cert_file
            options[:SSLPrivateKey] = @tls_key_file
          end
        end

        app = WebApp.new(@collector, auth: @auth, realm: @realm, logger: @logger)

        begin
          @logger.info "Start handler"
          @server = handler
          @server.run(app, **options)
          @logger.info "Finished handler"
        rescue Exception => e
          @logger.error "Server loop crashed: #{e.inspect}\n#{e.backtrace.join("\n")}"
          raise e
        end
      end
    end

    def stop
      @logger.info "Stop handler"
      if @server
        if @server.respond_to?(:shutdown)
          @server.shutdown
        elsif @server.respond_to?(:stop)
          @server.stop
        else
          @logger.info "Kill runner"
          @runner.kill if @runner
        end
      else
        @logger.info "Kill runner"
        @runner.kill if @runner
      end
    end
  end
end
