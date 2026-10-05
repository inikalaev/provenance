# frozen_string_literal: true

require "net/http"
require "uri"

module Provenance
  module Sinks
    # POSTs each batch as a JSON array. Any 2xx response is a success; other
    # responses and network errors are retried with exponential backoff and jitter.
    class HTTP
      # Errors treated as retryable network failures.
      NETWORK_ERRORS = [
        IOError, SystemCallError, SocketError, Timeout::Error, OpenSSL::SSL::SSLError, Net::ProtocolError
      ].freeze

      # @return [URI::HTTP]
      attr_reader :uri

      # @param url [String]
      # @param headers [Hash{String => String}]
      # @param open_timeout [Numeric] seconds
      # @param read_timeout [Numeric] seconds
      # @param retries [Integer] retries after the first attempt
      # @param backoff [Numeric] base delay in seconds, doubled per retry
      # @param max_backoff [Numeric] delay cap in seconds
      # @param sleeper [#call] receives the delay; replaceable in tests
      def initialize(url:, headers: {}, open_timeout: 2, read_timeout: 5, retries: 3, backoff: 0.5,
        max_backoff: 30, sleeper: ->(seconds) { sleep(seconds) })
        @uri = URI.parse(url.to_s)
        raise ConfigurationError, "http sink needs an http(s) url" unless @uri.is_a?(URI::HTTP)

        @headers = {"Content-Type" => "application/json"}.merge(headers.transform_keys(&:to_s))
        @open_timeout = open_timeout
        @read_timeout = read_timeout
        @retries = retries
        @backoff = backoff
        @max_backoff = max_backoff
        @sleeper = sleeper
      end

      # @param batch [Array<Hash>]
      # @return [void]
      # @raise [DeliveryError] when every attempt failed
      def deliver(batch)
        body = JSON.generate(batch)
        attempt = 0
        begin
          post(body)
        rescue DeliveryError, *NETWORK_ERRORS => e
          raise DeliveryError, "#{uri.host}: #{e.message}" if attempt >= @retries

          @sleeper.call(delay(attempt))
          attempt += 1
          retry
        end
      end

      # @param attempt [Integer] zero-based retry number
      # @return [Float] seconds to wait before the retry
      def delay(attempt)
        base = [@backoff * (2**attempt), @max_backoff].min
        base / 2.0 + rand * base / 2.0
      end

      private

      def post(body)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = @open_timeout
        http.read_timeout = @read_timeout
        request = Net::HTTP::Post.new(uri.request_uri, @headers)
        request.body = body
        response = http.request(request)
        return response if response.code.to_i.between?(200, 299)

        raise DeliveryError, "HTTP #{response.code}"
      end
    end
  end
end
