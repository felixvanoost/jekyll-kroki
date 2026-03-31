# frozen_string_literal: true

module Jekyll
  class Kroki
    # Reads, validates, and exposes the jekyll-kroki configuration from the Jekyll site config.
    class Config
      DEFAULT_KROKI_URL = "https://kroki.io"
      DEFAULT_HTTP_RETRIES = 3
      DEFAULT_HTTP_TIMEOUT = 15
      DEFAULT_MAX_CONCURRENT_DOCS = 8

      attr_reader :kroki_url, :http_retries, :http_timeout, :max_concurrent_docs

      # @param [Hash] The Jekyll site configuration.
      # @raise [TypeError] If any parameter has an incorrect type.
      # @raise [ArgumentError] If any parameter is out of the valid range.
      def initialize(site_config)
        kroki_config = site_config.fetch("kroki", {})

        @kroki_url = parse_url(kroki_config)
        @http_retries = parse_integer(kroki_config, "http_retries", DEFAULT_HTTP_RETRIES, min: 0)
        @http_timeout = parse_integer(kroki_config, "http_timeout", DEFAULT_HTTP_TIMEOUT, min: 0)
        @max_concurrent_docs = parse_integer(kroki_config, "max_concurrent_docs", DEFAULT_MAX_CONCURRENT_DOCS, min: 1)

        freeze
      end

      private

      def parse_url(kroki_config)
        param_name = "url"
        raw = kroki_config.fetch(param_name, DEFAULT_KROKI_URL)
        uri = URI.parse(raw)
        raise TypeError, "'#{param_name}' is not a valid HTTP URL" unless uri.is_a?(URI::HTTP)

        uri
      end

      def parse_integer(kroki_config, param_name, default, min:)
        value = kroki_config.fetch(param_name, default)
        raise TypeError, "'#{param_name}' must be an integer" unless value.is_a?(Integer)
        raise ArgumentError, "'#{param_name}' must be >= #{min}" if value < min

        value
      end
    end
  end
end
