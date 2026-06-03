# frozen_string_literal: true

require_relative "../test_helper"
require "prometheus_exporter/server"
require "rack/mock"

class PrometheusExporterWebAppTest < Minitest::Test
  def setup
    PrometheusExporter::Metric::Base.default_prefix = ""
  end

  def build_app
    collector = PrometheusExporter::Server::Collector.new
    [PrometheusExporter::Server::WebApp.new(collector), collector]
  end

  def post(app, body)
    app.call(Rack::MockRequest.env_for("/send-metrics", method: "POST", input: body))
  end

  def test_processes_ndjson_batch_and_isolates_bad_lines
    app, collector = build_app
    body = [
      '{"type":"gauge","name":"g1","help":"h","value":5}',
      "not json at all",
      '{"type":"gauge","name":"g2","help":"h","value":7}',
    ].join("\n")

    status, _headers, _response = post(app, body)

    assert_equal(200, status)

    text = collector.prometheus_metrics_text
    assert_match(/g1 5/, text)
    assert_match(/g2 7/, text)
  end

  def test_bad_line_increments_bad_metrics_counter
    app, _collector = build_app
    post(app, ["not json", '{"type":"gauge","name":"ok","help":"h","value":1}'].join("\n"))

    status, _headers, response = app.call(Rack::MockRequest.env_for("/metrics", method: "GET"))

    assert_equal(200, status)
    assert_match(/collector_bad_metrics_total 1/, response.each.to_a.join)
  end

  def test_empty_body_is_ok
    app, _collector = build_app
    status, _headers, _response = post(app, "")
    assert_equal(200, status)
  end
end
