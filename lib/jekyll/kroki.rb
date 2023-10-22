# frozen_string_literal: true

require_relative "kroki/version"

require "base64"
require "faraday"
require "faraday/retry"
require "jekyll"
require "nokogiri"
require "zlib"

module Jekyll
  # Converts diagram descriptions into images using Kroki
  class Kroki
    KROKI_DEFAULT_URL = "https://kroki.io"
    HTTP_MAX_RETRIES = 3

    class << self
      # Renders all diagram descriptions written in a Kroki-supported language in an HTML document.
      #
      # @param [Jekyll::Page or Jekyll::Document] The document to embed diagrams in
      def embed(doc)
        # Get the URL of the Kroki instance
        kroki_url = kroki_url(doc.site.config)
        puts "[jekyll-kroki] Rendering diagrams in '#{doc.name}' using Kroki instance '#{kroki_url}'"

        # Set up a Faraday connection
        connection = setup_connection(kroki_url)

        # Parse the HTML document, render and embed the diagrams, then convert it back into HTML
        parsed_doc = Nokogiri::HTML(doc.output)
        embed_diagrams_in_doc(connection, parsed_doc)
        doc.output = parsed_doc.to_html
      end

      # Renders all diagram descriptions in any Kroki-supported language and embeds them in an HTML document.
      #
      # @param [Faraday::Connection] The Faraday connection to use
      # @param [Nokogiri::HTML4::Document] The parsed HTML document
      def embed_diagrams_in_doc(connection, parsed_doc)
        # Iterate through every diagram description in each of the supported languages
        get_supported_languages(connection).each do |language|
          parsed_doc.css("code[class~='language-#{language}']").each do |diagram_desc|
            # Replace the diagram description with the SVG representation rendered by Kroki
            diagram_desc.replace(render_diagram(connection, diagram_desc, language))
          end
        end
      end

      # Renders a diagram description using Kroki.
      #
      # @param [Faraday::Connection] The Faraday connection to use
      # @param [String] The diagram description
      # @param [String] The language of the diagram description
      # @return [String] The rendered diagram in SVG format
      def render_diagram(connection, diagram_desc, language)
        begin
          encoded_diagram = encode_diagram(diagram_desc.text)
          response = connection.get("#{language}/svg/#{encoded_diagram}")
        rescue Faraday::Error => e
          raise e.response[:body]
        end
        response.body
      end

      # Encodes the diagram into Kroki format using deflate + base64.
      # See https://docs.kroki.io/kroki/setup/encode-diagram/.
      #
      # @param [String, #read] The diagram description to encode
      # @return [String] The encoded diagram
      def encode_diagram(diagram_desc)
        Base64.urlsafe_encode64(Zlib.deflate(diagram_desc))
      end

      # Gets an array of supported diagram languages from the Kroki '/health' endpoint.
      #
      # This only shows which languages the Kroki project supports, not which ones are currently available from the
      # configured Kroki instance. For example, Mermaid will still show up as a supported language even if the Mermaid
      # companion container is not running.
      #
      # @param [Faraday::Connection] The Faraday connection to use
      # @return [Array] The supported diagram languages
      def get_supported_languages(connection)
        begin
          response = connection.get("health")
        rescue Faraday::Error => e
          raise e.response[:body]
        end
        response.body["version"].keys
      end

      # Sets up a new Faraday connection.
      #
      # @param [URI::HTTP] The URL of the Kroki instance
      # @return [Faraday::Connection] The Faraday connection
      def setup_connection(kroki_url)
        retry_options = { max: HTTP_MAX_RETRIES, interval: 0.1, interval_randomness: 0.5, backoff_factor: 2,
                          exceptions: [Faraday::RequestTimeoutError, Faraday::ServerError] }

        Faraday.new(url: kroki_url) do |builder|
          builder.request :retry, retry_options
          builder.response :json, content_type: /\bjson$/
          builder.response :raise_error
        end
      end

      # Gets the URL of the Kroki instance to use for rendering diagrams.
      #
      # @param The Jekyll site configuration
      # @return [URI::HTTP] The URL of the Kroki instance
      def kroki_url(config)
        if config.key?("jekyll-kroki") && config["jekyll-kroki"].key?("kroki_url")
          url = config["jekyll-kroki"]["kroki_url"]
          raise TypeError, "'kroki_url' is not a valid HTTP URL" unless URI.parse(url).is_a?(URI::HTTP)

          URI(url)
        else
          URI(KROKI_DEFAULT_URL)
        end
      end

      # Determines whether a document may contain embeddable diagram descriptions - it is in HTML format and is either
      # a Jekyll::Page or writeable Jekyll::Document.
      #
      # @param [Jekyll::Page or Jekyll::Document] The document to check for embedability
      def embeddable?(doc)
        doc.output_ext == ".html" && (doc.is_a?(Jekyll::Page) || doc.write?)
      end
    end
  end
end

Jekyll::Hooks.register [:pages, :documents], :post_render do |doc|
  Jekyll::Kroki.embed(doc) if Jekyll::Kroki.embeddable?(doc)
end
