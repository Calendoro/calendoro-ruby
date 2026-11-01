# frozen_string_literal: true

require "json"
require "openssl"

module Calendoro
  # Webhook signature verification, matching packages/webhooks.
  module Webhook
    class SignatureError < Calendoro::Error
      def initialize(message = "invalid webhook signature")
        super
      end
    end

    # True when the Calendoro-Signature header signs the raw body with secret recently enough. False, never an exception, on bad input.
    def self.verify_signature(header, secret, body, now: Time.now.to_i, tolerance: 300)
      text = header.is_a?(::Array) ? header.join(",") : header
      return false unless text.is_a?(::String)

      timestamp = nil
      signatures = []
      text.split(",", -1).each do |part|
        key, sep, value = part.partition("=")
        next if sep.empty?

        key = key.strip
        value = value.strip
        if key == "t" && value.match?(/\A[0-9]+\z/)
          timestamp = value.to_i
        elsif key == "v1"
          signatures << value
        end
      end
      return false if timestamp.nil? || (now - timestamp).abs > tolerance

      expected = OpenSSL::HMAC.digest("SHA256", secret, "#{timestamp}.#{body}".b)
      signatures.any? do |s|
        next false unless s.match?(/\A(?:[0-9a-fA-F]{2})*\z/)

        got = [s].pack("H*")
        got.bytesize == expected.bytesize && OpenSSL.fixed_length_secure_compare(got, expected)
      end
    end

    # Verifies a delivery and returns the parsed event. Raises SignatureError otherwise. Pass the raw request body.
    def self.construct_event(body, header, secret, now: Time.now.to_i, tolerance: 300)
      raise SignatureError unless verify_signature(header, secret, body, now: now, tolerance: tolerance)

      JSON.parse(body)
    end
  end
end
