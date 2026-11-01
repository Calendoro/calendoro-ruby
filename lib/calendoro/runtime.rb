# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "securerandom"
require "uri"

module Calendoro
  class Error < StandardError; end
  class ConnectionError < Error; end
  class TimeoutError < ConnectionError; end

  # The API answered with an error. Quote #request_id to support.
  class APIError < Error
    attr_reader :status, :code, :details, :request_id, :retry_after

    def initialize(status, code, message, details, request_id, retry_after)
      super("#{status} #{code}: #{message}#{" (request #{request_id})" if request_id}")
      @status = status
      @code = code
      @details = details
      @request_id = request_id
      @retry_after = retry_after
    end
  end

  class ValidationError < APIError; end
  class AuthenticationError < APIError; end
  class PermissionDeniedError < APIError; end
  class NotFoundError < APIError; end
  class ConflictError < APIError; end
  class RateLimitError < APIError; end
  class ServerError < APIError; end

  ERROR_CLASSES = { 400 => ValidationError, 401 => AuthenticationError, 403 => PermissionDeniedError, 404 => NotFoundError, 409 => ConflictError, 429 => RateLimitError }.freeze

  # Typed response and request object. Unknown fields are kept in #to_h, so newer servers do not break older clients.
  class Model
    def self.fields
      @fields ||= {}
    end

    def self.field(name, wire, type)
      fields[name] = [wire, type]
      attr_accessor name
    end

    def self.coerce(value, type)
      return value if value.nil? || type.nil?
      case type
      when ::String then value.is_a?(::Hash) ? Models.const_get(type).from_h(value) : value
      when ::Array then value.is_a?(::Array) ? value.map { |v| coerce(v, type[0]) } : value
      else value.is_a?(::Hash) ? value.transform_values { |v| coerce(v, type[:of]) } : value
      end
    end

    def self.from_h(hash)
      m = allocate
      m.instance_variable_set(:@raw, hash)
      fields.each { |name, (wire, type)| m.public_send("#{name}=", coerce(hash[wire], type)) }
      m
    end

    def initialize(**attrs)
      @raw = {}
      attrs.each { |k, v| public_send("#{k}=", v) }
    end

    def to_h
      out = @raw.dup
      self.class.fields.each do |name, (wire, _type)|
        v = public_send(name)
        out[wire] = Model.dump(v) unless v.nil?
      end
      out
    end

    def self.dump(v)
      case v
      when Model then v.to_h
      when ::Array then v.map { |x| dump(x) }
      when ::Hash then v.transform_values { |x| dump(x) }
      else v
      end
    end
  end

  class BaseClient
    RETRYABLE = [408, 429, 500, 502, 503, 504].freeze
    SAFE = %i[get put delete].freeze
    REQUESTS = { get: Net::HTTP::Get, post: Net::HTTP::Post, put: Net::HTTP::Put, patch: Net::HTTP::Patch, delete: Net::HTTP::Delete }.freeze
    NETWORK_ERRORS = [SocketError, SystemCallError, IOError, EOFError, OpenSSL::SSL::SSLError].freeze

    def initialize(api_key: nil, oauth_token: nil, session_token: nil, base_url: "https://api.calendoro.app", timeout: 30, max_retries: 2)
      @token = api_key || oauth_token || session_token
      @base_url = base_url.sub(%r{/+\z}, "")
      @timeout = timeout
      @max_retries = max_retries
    end

    def request(method, path, path_params: {}, query: {}, body: nil, idempotent: false, idempotency_key: nil, timeout: nil, type: nil)
      path_params.each { |k, v| path = path.sub("{#{k}}", URI.encode_www_form_component(v.to_s).gsub("+", "%20")) }
      pairs = query.flat_map { |k, v| Array(v).compact.map { |x| [k, x.to_s] } }
      uri = URI(@base_url + path + (pairs.empty? ? "" : "?#{URI.encode_www_form(pairs)}"))
      headers = { "Accept" => "application/json", "User-Agent" => "calendoro-ruby/#{VERSION}" }
      headers["Authorization"] = "Bearer #{@token}" if @token
      headers["Idempotency-Key"] = idempotency_key || SecureRandom.uuid if idempotent # one key for every retry of this call
      payload = nil
      unless body.nil?
        headers["Content-Type"] = "application/json"
        payload = JSON.generate(Model.dump(body))
      end
      # A POST or PATCH without a key may already have taken effect, so only a 429, which the server refused up front, is safe to repeat.
      safe = idempotent || SAFE.include?(method)
      attempt = 0
      begin
        Model.coerce(once(method, uri, headers, payload, timeout || @timeout), type)
      rescue APIError => e
        raise if attempt >= @max_retries || !RETRYABLE.include?(e.status) || (!safe && e.status != 429)

        sleep(e.retry_after ? [e.retry_after, 60].min : backoff(attempt))
        attempt += 1
        retry
      rescue ConnectionError
        raise if attempt >= @max_retries || !safe

        sleep(backoff(attempt))
        attempt += 1
        retry
      end
    end

    def paginate(method, path, query: {}, type: nil, **rest)
      Enumerator.new do |y|
        params = query.dup
        loop do
          page = request(method, path, query: params, **rest)
          (page["data"] || []).each { |item| y << Model.coerce(item, type) }
          cursor = page["nextCursor"]
          break if cursor.nil? || cursor.empty?

          params["cursor"] = cursor
        end
      end
    end

    private

    # Exponential backoff with full jitter.
    def backoff(attempt)
      rand * [8.0, 0.5 * (2**attempt)].min
    end

    def once(method, uri, headers, payload, timeout)
      req = REQUESTS.fetch(method).new(uri, headers)
      req.body = payload if payload
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: timeout, read_timeout: timeout, write_timeout: timeout, max_retries: 0) { |h| h.request(req) }
      raise api_error(res) if res.code.to_i >= 400

      res.body.nil? || res.body.empty? ? nil : parse(res.body)
    rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout => e
      raise TimeoutError, e.message
    rescue *NETWORK_ERRORS => e
      raise ConnectionError, e.message
    end

    def parse(text)
      JSON.parse(text)
    rescue JSON::ParserError
      text
    end

    def api_error(res)
      parsed = parse(res.body.to_s)
      err = parsed.is_a?(::Hash) && parsed["error"].is_a?(::Hash) ? parsed["error"] : {}
      status = res.code.to_i
      klass = status >= 500 ? ServerError : ERROR_CLASSES.fetch(status, APIError)
      retry_after = Float(res["retry-after"], exception: false)
      klass.new(status, err.fetch("code", "http_error"), err.fetch("message", "HTTP #{status}"), err["details"], res["x-request-id"] || err["requestId"], retry_after && [retry_after, 0].max)
    end
  end
end
