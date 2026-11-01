# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "socket"
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "calendoro"

# A tiny HTTP stub on a raw socket, because WEBrick left the standard library.
class Stub
  attr_reader :seen, :port
  attr_accessor :failures

  def initialize
    @seen = []
    @failures = []
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @thread = Thread.new { loop { Thread.new(@server.accept) { |s| serve(s) } } }
  end

  def serve(sock)
    head = sock.gets("\r\n\r\n")
    return unless head

    line, *rest = head.split("\r\n")
    method, path = line.split
    headers = rest.to_h { |h| k, v = h.split(": ", 2); [k.downcase, v] }
    sock.read(headers["content-length"].to_i) if headers["content-length"]
    @seen << { method: method, path: path, headers: headers }
    status, body, extra = route(method, path)
    sock.write("HTTP/1.1 #{status} X\r\nContent-Type: application/json\r\nX-Request-Id: req_stub\r\n#{extra}Connection: close\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}")
  rescue IOError, SystemCallError
    nil
  ensure
    sock.close
  end

  def route(method, path)
    if (f = @failures.shift)
      return [f, '{"error":{"code":"stub_failure","message":"try again"}}', "Retry-After: 0\r\n"]
    end
    sleep 1 if path.start_with?("/slow")
    return [200, '{"data":[{"id":"whk_2"}],"nextCursor":null}'] if path.start_with?("/v1/webhooks") && path.include?("cursor=p2")
    return [200, '{"data":[{"id":"whk_1"}],"nextCursor":"p2"}'] if path.start_with?("/v1/webhooks")
    return [200, '{"organizationId":"org_1"}'] if path == "/v1/me"
    return [201, '{"id":"bkg_1","status":"confirmed"}'] if path == "/v1/bookings" && method == "POST"
    return [500, '{"error":{"code":"internal","message":"boom"}}'] if ["/v1/event-types", "/v1/auth/login"].include?(path) && method == "POST"

    [404, '{"error":{"code":"not_found","message":"nope","details":["x"]}}']
  end
end

class SdkTest < Minitest::Test
  STUB = Stub.new
  URL = "http://127.0.0.1:#{STUB.port}".freeze
  VECTORS = JSON.parse(File.read(File.expand_path("../fixtures/webhook-vectors.json", __dir__)))

  def setup
    STUB.seen.clear
    STUB.failures.clear
    @client = Calendoro::Client.new(api_key: "cdo_key", base_url: URL)
  end

  def test_auth
    assert_equal "org_1", @client.account.get_api_identity.organization_id
    assert_equal "Bearer cdo_key", STUB.seen[0][:headers]["authorization"]
    Calendoro::Client.new(oauth_token: "cdoa_t", base_url: URL).account.get_api_identity
    assert_equal "Bearer cdoa_t", STUB.seen[1][:headers]["authorization"]
  end

  def test_retries_then_gives_up
    STUB.failures.push(503)
    @client.account.get_api_identity
    assert_equal 2, STUB.seen.size
    STUB.seen.clear
    STUB.failures.push(503, 503, 503)
    assert_raises(Calendoro::ServerError) { @client.account.get_api_identity }
    assert_equal 3, STUB.seen.size
  end

  def test_idempotency_key_stable_across_retries
    STUB.failures.push(503)
    assert_equal "bkg_1", @client.bookings.create_booking({ eventTypeId: "e" }).id
    keys = STUB.seen.map { |s| s[:headers]["idempotency-key"] }
    assert_equal 2, keys.size
    assert keys[0]
    assert_equal keys[0], keys[1]
    @client.bookings.create_booking({ eventTypeId: "e" }, idempotency_key: "mine")
    assert_equal "mine", STUB.seen.last[:headers]["idempotency-key"]
  end

  def test_write_without_key_not_retried_on_500
    assert_raises(Calendoro::ServerError) { @client.authentication.login({ email: "a@example.com", password: "password" }) }
    assert_equal 1, STUB.seen.size
    assert_nil STUB.seen[0][:headers]["idempotency-key"]
  end

  def test_iterator_follows_cursor
    assert_equal %w[whk_1 whk_2], @client.webhooks.list_webhooks_iter.map(&:id)
    assert_equal 2, STUB.seen.size
  end

  def test_typed_error_carries_request_id
    e = assert_raises(Calendoro::NotFoundError) { @client.event_types.get_event_type("a/b") }
    assert_equal [404, "not_found", "req_stub", ["x"]], [e.status, e.code, e.request_id, e.details]
    assert_equal "/v1/event-types/a%2Fb", STUB.seen[0][:path]
  end

  def test_timeout
    client = Calendoro::Client.new(api_key: "k", base_url: URL, timeout: 0.1, max_retries: 0)
    assert_raises(Calendoro::TimeoutError) { client.request(:get, "/slow") }
  end

  def test_webhook_vectors_match_packages_webhooks
    VECTORS.each do |v|
      got = Calendoro::Webhook.verify_signature(v["header"], v["secret"], v["body"], now: v["now"], tolerance: v.fetch("tolerance", 300))
      assert_equal v["valid"], got, v["name"]
    end
  end

  def test_construct_event
    v = VECTORS[0]
    assert_equal "wev_1", Calendoro::Webhook.construct_event(v["body"], v["header"], v["secret"], now: v["now"])["id"]
    assert_raises(Calendoro::Webhook::SignatureError) { Calendoro::Webhook.construct_event(v["body"], nil, v["secret"]) }
  end
end
