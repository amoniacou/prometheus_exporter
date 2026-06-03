# frozen_string_literal: true

require_relative "test_helper"
require "prometheus_exporter/client"

# Records everything written and replays a canned HTTP response, so we can
# assert the exact bytes the client puts on the wire without a real server.
class FakeKeepAliveSocket
  attr_reader :written

  def initialize(response)
    @written = +""
    @response = StringIO.new(response)
    @closed = false
  end

  def write(str)
    @written << str.to_s
    str.to_s.bytesize
  end

  def flush; end

  def gets
    @response.gets
  end

  def read(length = nil)
    @response.read(length)
  end

  def close
    @closed = true
  end

  def closed?
    @closed
  end
end

class PrometheusExporterTest < Minitest::Test
  def test_find_the_correct_registered_metric
    client = PrometheusExporter::Client.new

    # register a metrics for testing
    counter_metric = client.register(:counter, "counter_metric", "helping")

    # when the given name doesn't match any existing metric, it returns nil
    result = client.find_registered_metric("not_registered")
    assert_nil(result)

    # when the given name matches an existing metric, it returns this metric
    result = client.find_registered_metric("counter_metric")
    assert_equal(counter_metric, result)

    # when the given name matches an existing metric, but the given type doesn't, it returns nil
    result = client.find_registered_metric("counter_metric", type: :gauge)
    assert_nil(result)

    # when the given name and type match an existing metric, it returns the metric
    result = client.find_registered_metric("counter_metric", type: :counter)
    assert_equal(counter_metric, result)

    # when the given name matches an existing metric, but the given help doesn't, it returns nil
    result = client.find_registered_metric("counter_metric", help: "not helping")
    assert_nil(result)

    # when the given name and help match an existing metric, it returns the metric
    result = client.find_registered_metric("counter_metric", help: "helping")
    assert_equal(counter_metric, result)

    # when the given name matches an existing metric, but the given help and type don't, it returns nil
    result = client.find_registered_metric("counter_metric", type: :gauge, help: "not helping")
    assert_nil(result)

    # when the given name, type, and help all match an existing metric, it returns the metric
    result = client.find_registered_metric("counter_metric", type: :counter, help: "helping")
    assert_equal(counter_metric, result)
  end

  def test_standard_values
    client = PrometheusExporter::Client.new
    counter_metric = client.register(:counter, "counter_metric", "helping")
    assert_equal(false, counter_metric.standard_values("value", "key").has_key?(:opts))

    expected_quantiles = { quantiles: [0.99, 9] }
    summary_metric = client.register(:summary, "summary_metric", "helping", expected_quantiles)
    assert_equal(expected_quantiles, summary_metric.standard_values("value", "key")[:opts])
  end

  def test_close_socket_on_error
    logs = StringIO.new
    logger = Logger.new(logs)
    logger.level = :error

    client =
      PrometheusExporter::Client.new(logger: logger, port: 321, process_queue_once_and_stop: true)
    client.send("put a message in the queue")

    assert_includes(
      logs.string,
      "Prometheus Exporter, failed to send message Connection refused - connect(2) for \"localhost\" port 321",
    )
  end

  def test_overriding_logger
    logs = StringIO.new
    logger = Logger.new(logs)
    logger.level = :warn

    client =
      PrometheusExporter::Client.new(
        logger: logger,
        max_queue_size: 1,
        process_queue_once_and_stop: true,
      )
    client.send("put a message in the queue")
    client.send("put a second message in the queue to trigger the logger")

    assert_includes(logs.string, "dropping message cause queue is full")
  end

  KEEP_ALIVE_RESPONSE = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nOK"
  CLOSE_RESPONSE = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK"

  def stub_socket(client, socket)
    client.instance_variable_set(:@socket, socket)
    client.define_singleton_method(:ensure_socket!) {}
  end

  def test_sends_queued_metrics_as_single_batched_post
    client = PrometheusExporter::Client.new
    queue = client.instance_variable_get(:@queue)
    queue << '{"m":1}'
    queue << '{"m":2}'

    socket = FakeKeepAliveSocket.new(KEEP_ALIVE_RESPONSE)
    stub_socket(client, socket)

    client.__send__(:process_queue)

    assert_equal(
      1,
      socket.written.scan("POST /send-metrics").length,
      "the whole batch must go out as a single POST",
    )
    assert_includes(socket.written, "Connection: keep-alive\r\n")

    body = "{\"m\":1}\n{\"m\":2}"
    assert_includes(socket.written, "Content-Length: #{body.bytesize}\r\n")
    assert(socket.written.end_with?(body), "body must be the newline-joined metrics")
    assert(queue.empty?, "queue must be drained")
  end

  def test_reuses_socket_when_server_keeps_alive
    client = PrometheusExporter::Client.new
    client.instance_variable_get(:@queue) << '{"m":1}'
    socket = FakeKeepAliveSocket.new(KEEP_ALIVE_RESPONSE)
    stub_socket(client, socket)

    client.__send__(:process_queue)

    refute(socket.closed?, "socket must stay open for keep-alive reuse")
    assert_equal(socket, client.instance_variable_get(:@socket))
  end

  def test_closes_socket_when_server_responds_connection_close
    client = PrometheusExporter::Client.new
    client.instance_variable_get(:@queue) << '{"m":1}'
    socket = FakeKeepAliveSocket.new(CLOSE_RESPONSE)
    stub_socket(client, socket)

    client.__send__(:process_queue)

    assert(socket.closed?, "socket must close when server responds Connection: close")
    assert_nil(client.instance_variable_get(:@socket))
  end
end
