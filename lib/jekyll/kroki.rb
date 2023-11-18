# frozen_string_literal: true

require_relative "kroki/version"

require "base64"
require "faraday"
require "faraday/retry"
require "httpx/adapters/faraday"
require "jekyll"
require "nokogiri"
require "zlib"

module Jekyll
  # Converts diagram descriptions into images using Kroki
  class Kroki
    KROKI_DEFAULT_URL = "https://kroki.io"
    HTTP_MAX_RETRIES = 3

    class << self
      # Renders and embeds all diagram descriptions in a Jekyll site using Kroki.
      #
      # @param [Jekyll::Site] The Jekyll site to embed diagrams in
      def embed_site(site)
        # Get the URL of the Kroki instance
        kroki_url = kroki_url(site.config)
        puts "[jekyll-kroki] Rendering diagrams using Kroki instance at '#{kroki_url}'"

        connection = setup_connection(kroki_url)
        supported_languages = get_supported_languages(connection)

        site.documents.each do |doc|
          next unless embeddable?(doc)

          # Parse the HTML document, render and embed the diagrams, then convert it back into HTML
          parsed_doc = Nokogiri::HTML(doc.output)
          embed_doc(connection, supported_languages, parsed_doc)
          doc.output = parsed_doc.to_html
        end
      rescue StandardError => e
        exit(e)
      end

      # Renders all diagram descriptions in a document and embeds them as inline SVGs in the HTML source.
      #
      # @param [Faraday::Connection] The Faraday connection to use
      # @param [Array] The supported diagram languages
      # @param [Nokogiri::HTML4::Document] The parsed HTML document
      def embed_doc(connection, supported_languages, parsed_doc)
        supported_languages.each do |language|
          parsed_doc.css("code[class~='language-#{language}']").each do |diagram_desc|
            # Replace the diagram description with the SVG representation rendered by Kroki
            diagram_desc.replace(render_diagram(connection, diagram_desc, language))
          end
        end
      end

      # Renders a single diagram description using Kroki.
      #
      # @param [Faraday::Connection] The Faraday connection to use
      # @param [String] The diagram description
      # @param [String] The language of the diagram description
      # @return [String] The rendered diagram in SVG format
      def render_diagram(connection, diagram_desc, language)
        begin
          response = connection.get("#{language}/svg/#{encode_diagram(diagram_desc.text)}")
        rescue Faraday::Error => e
          raise e.response[:body]
        end
        expected_content_type = "image/svg+xml"
        returned_content_type = response.headers[:content_type]
        if returned_content_type != expected_content_type
          raise "Kroki returned an incorrect content type: " \
                "expected '#{expected_content_type}', received '#{returned_content_type}'"

        end
        sanitise_diagram(response.body)
      end

      # Sanitises a rendered diagram. Only <script> elements are removed, which is the most minimal / naive
      # implementation possible and is definitely not secure.
      #
      # @param [String] The diagram to santise in SVG format
      # @return [String] The sanitized diagram in SVG format
      def sanitise_diagram(diagram_svg)
        parsed_svg = Nokogiri::XML(diagram_svg)
        parsed_svg.xpath('//*[name()="script"]').each(&:remove)
        parsed_svg.to_xml
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
        response = connection.get("health")
        supported_languages = response.body["version"]&.keys
        raise "'#{connection.url_prefix}' does not point to a valid Kroki instance" if supported_languages.nil?

        supported_languages
      rescue Faraday::Error => e
        raise e
      end

      # Sets up a new Faraday connection.
      #
      # @param [URI::HTTP] The URL of the Kroki instance
      # @return [Faraday::Connection] The Faraday connection
      def setup_connection(kroki_url)
        retry_options = { max: HTTP_MAX_RETRIES, interval: 0.1, interval_randomness: 0.5, backoff_factor: 2,
                          exceptions: [Faraday::RequestTimeoutError, Faraday::ServerError] }

        Faraday.new(url: kroki_url, request: { timeout: 5 }) do |builder|
          builder.adapter :httpx, persistent: true
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
        if config.key?("kroki") && config["kroki"].key?("url")
          url = config["kroki"]["url"]
          raise TypeError, "'url' is not a valid HTTP URL" unless URI.parse(url).is_a?(URI::HTTP)

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

      # Exits the Jekyll process without returning a stack trace. This method does not return because the process is
      # abruptly terminated.
      #
      # @param [StandardError] The error to display in the termination message
      # @param [int] The caller index to display in the termination message. The default index is 1, which means the
      #              calling method. To specify the calling method's caller, pass in 2.
      #
      # Source: https://www.mslinn.com/ruby/2200-crash-exit.html
      def exit(error, caller_index = 1)
        raise error
      rescue StandardError => e
        file, line_number, caller = e.backtrace[caller_index].split(":")
        caller = caller.tr("`", "'")
        warn %([jekyll-kroki] "#{error.message}" #{caller} on line #{line_number} of #{file}).red
        exec "echo ''"
      end
    end
  end
end

Jekyll::Hooks.register :site, :post_render do |site|
  Jekyll::Kroki.embed_site(site)
end
