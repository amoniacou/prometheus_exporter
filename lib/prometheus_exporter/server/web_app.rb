# frozen_string_literal: true

require "rack"
require "zlib"
require "stringio"
require "logger"

module PrometheusExporter::Server
  class WebApp
    PAGESIZE =
      begin
        `getconf PAGESIZE`.to_i
      rescue StandardError
        4096
      end
    private_constant :PAGESIZE

    def initialize(collector, auth: nil, realm: nil, logger: nil)
      @collector = collector
      @auth = auth
      @realm = realm || PrometheusExporter::DEFAULT_REALM
      @logger = logger || Logger.new(File::NULL)
      @pid = Process.pid

      @metrics_total =
        PrometheusExporter::Metric::Counter.new(
          "collector_metrics_total",
          "Total metrics processed by exporter web.",
        )

      @sessions_total =
        PrometheusExporter::Metric::Counter.new(
          "collector_sessions_total",
          "Total send_metric sessions processed by exporter web.",
        )

      @bad_metrics_total =
        PrometheusExporter::Metric::Counter.new(
          "collector_bad_metrics_total",
          "Total mis-handled metrics by collector.",
        )

      @metrics_total.observe(0)
      @sessions_total.observe(0)
      @bad_metrics_total.observe(0)
    end

    def call(env)
      req = Rack::Request.new(env)
      res = Rack::Response.new
      res["Content-Type"] = "text/plain; charset=utf-8"

      if req.path == "/metrics"
        if @auth
          unless authenticate(req, res)
            return res.finish
          end
        end

        res.status = 200
        if req.env["HTTP_ACCEPT_ENCODING"].to_s.include?("gzip")
          sio = StringIO.new
          begin
            writer = Zlib::GzipWriter.new(sio)
            writer.write(collected_metrics)
          ensure
            writer.close
          end
          res.write(sio.string)
          res["Content-Encoding"] = "gzip"
        else
          res.write(collected_metrics)
        end
      elsif req.path == "/send-metrics"
        handle_metrics(req, res)
      elsif req.path == "/ping"
        res.write("PONG")
      else
        res.status = 404
        res.write(
          "Not Found! The Prometheus Ruby Exporter only listens on /ping, /metrics and /send-metrics"
        )
      end
      @logger.info "finished request"
      res.finish
    rescue Exception => e
      @logger.error "Call crashed: #{e.inspect}\n#{e.backtrace.join("\n")}"
      [500, { "Content-Type" => "text/plain" }, ["Internal Server Error"]]
    end

    private

    def handle_metrics(req, res)
      @sessions_total.observe
      begin
        req.body.each do |chunk|
          @metrics_total.observe
          @collector.process(chunk)
        end
        res.write("OK")
        res.status = 200
      rescue Exception => e
        @logger.error "\n\n#{e.inspect}\n#{e.backtrace}\n\n"
        @bad_metrics_total.observe
        res.write("Bad Metrics #{e}")
        res.status = e.respond_to?(:status_code) ? e.status_code : 500
      end
    end

    def collected_metrics
      metric_text = nil
      begin
        # Use a default timeout if not provided or handle elsewhere, 
        # but WebApp doesn't hold config.
        # We can assume collector handles text generation reasonably fast or use a fixed small timeout here?
        # WebServer had @timeout.
        Timeout.timeout(2) { metric_text = @collector.prometheus_metrics_text }
      rescue Timeout::Error
        @logger.error "Generating Prometheus metrics text timed out"
      end

      metrics = []

      metrics << add_gauge(
        "collector_working",
        "Is the master process collector able to collect metrics",
        metric_text && metric_text.length > 0 ? 1 : 0,
      )

      metrics << add_gauge("collector_rss", "total memory used by collector process", get_rss)

      metrics << @metrics_total
      metrics << @sessions_total
      metrics << @bad_metrics_total

      [
        metrics.map(&:to_prometheus_text).join("\n\n"),
        metric_text
      ].join("\n")
    end

    def get_rss
      begin
        File.read("/proc/#{@pid}/statm").split(" ")[1].to_i * PAGESIZE
      rescue StandardError
        0
      end
    end

    def add_gauge(name, help, value)
      gauge = PrometheusExporter::Metric::Gauge.new(name, help)
      gauge.observe(value)
      gauge
    end

    def authenticate(req, res)
      auth = Rack::Auth::Basic::Request.new(req.env)

      if auth.provided? && auth.basic? && auth.credentials
        user, password = auth.credentials
        if verify_credentials(user, password)
          return true
        end
      end

      res.status = 401
      res["WWW-Authenticate"] = %(Basic realm="#{@realm}")
      res.write("Unauthorized")
      false
    end

    def verify_credentials(user, password)
      return false unless @auth && File.exist?(@auth)

      File.foreach(@auth) do |line|
        next if line.strip.empty? || line.start_with?("#")
        file_user, file_hash = line.strip.split(":", 2)
        if file_user == user
          return password.crypt(file_hash) == file_hash
        end
      end
      false
    rescue => e
      @logger.error "Error verifying credentials: #{e}"
      false
    end
  end
end
