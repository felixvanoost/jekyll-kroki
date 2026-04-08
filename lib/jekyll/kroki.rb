# frozen_string_literal: true

require_relative "kroki/config"
require_relative "kroki/version"

require "async"
require "async/semaphore"
require "base64"
require "concurrent-ruby"
require "digest"
require "faraday"
require "faraday/retry"
require "httpx/adapters/faraday"
require "jekyll"
require "nokogiri"
require "zlib"

module Jekyll
  # Converts diagram descriptions into images using Kroki.
  class Kroki
    SUPPORTED_LANGUAGES = %w[actdiag blockdiag bpmn bytefield c4plantuml d2 dbml diagramsnet ditaa erd excalidraw
                             graphviz mermaid nomnoml nwdiag packetdiag pikchr plantuml rackdiag seqdiag structurizr
                             svgbob symbolator tikz umlet vega vegalite wavedrom wireviz].freeze
    EXPECTED_HTML_TAGS = %w[code div].freeze
    DIAGRAM_SELECTOR = SUPPORTED_LANGUAGES.flat_map do |language|
      EXPECTED_HTML_TAGS.map { |tag| "#{tag}[class~='language-#{language}']" }
    end.join(", ").freeze

    HTTP_RETRY_INTERVAL_BACKOFF_FACTOR = 2
    HTTP_RETRY_INTERVAL_RANDOMNESS = 0.5
    HTTP_RETRY_INTERVAL = 0.1

    @diagram_cache = Concurrent::Map.new

    class << self
      # Renders and embeds all diagram descriptions in the given Jekyll site using Kroki.
      #
      # @param [Jekyll::Site] The Jekyll site to embed diagrams in.
      def embed_site(site)
        config = Config.new(site.config)
        connection = setup_connection(config.kroki_url, config.http_retries, config.http_timeout)

        rendered_diag = embed_docs_in_site(site, connection, config.max_concurrent_docs)
        return unless rendered_diag.positive?

        Jekyll.logger.info(
          "[jekyll-kroki] Rendered #{rendered_diag} diagrams using Kroki instance at '#{config.kroki_url}'"
        )
      end

      # Renders the diagram descriptions in all Jekyll pages and documents in the given Jekyll site. Pages / documents
      # are rendered concurrently up to the limit defined by max_concurrent_docs.
      #
      # @param [Jekyll::Site] The Jekyll site to embed diagrams in.
      # @param [Faraday::Connection] The Faraday connection to use.
      # @param [Integer] The maximum number of documents to render concurrently.
      # @return [Integer] The number of successfully rendered diagrams.
      def embed_docs_in_site(site, connection, max_concurrent_docs)
        semaphore = Async::Semaphore.new(max_concurrent_docs)

        Async do
          (site.pages + site.documents).filter_map do |doc|
            next unless embeddable?(doc)

            semaphore.async do
              embed_single_doc(connection, doc)
            rescue StandardError => e
              Jekyll.logger.error "[jekyll-kroki] Failed to render diagram in '#{doc.relative_path}': #{e.message}"
              0
            end
          end.sum(&:wait)
        end.wait
      end

      # Renders the supported diagram descriptions in a single document sequentially and embeds them as inline SVGs in
      # the HTML source. Returns without modifying the document if no supported diagram descriptions are found.
      #
      # @param [Faraday::Connection] The Faraday connection to use.
      # @param [Jekyll::Page, Jekyll::Document] The document to process.
      # @return [Integer] The number of successfully rendered diagrams.
      def embed_single_doc(connection, doc)
        parsed_doc = Nokogiri::HTML(doc.output)
        nodes = parsed_doc.css(DIAGRAM_SELECTOR)
        return 0 if nodes.empty?

        nodes.each do |node|
          # Extract the diagram language from the class list.
          language = node["class"].split.grep(/\Alanguage-/).first.delete_prefix("language-")
          node.replace(render_diagram(connection, node.text, language))
        end

        # Convert the document back to HTML.
        doc.output = parsed_doc.to_html
        nodes.size
      end

      # Renders a single diagram description using Kroki. The rendered diagram is cached to avoid redundant HTTP
      # requests across documents, using the diagram language and the SHA1 of the diagram description as the key.
      #
      # @param [Faraday::Connection] The Faraday connection to use.
      # @param [String] The diagram description.
      # @param [String] The language of the diagram description.
      # @return [String] The rendered diagram in SVG format.
      def render_diagram(connection, diagram_text, language)
        cache_key = "#{language}:#{Digest::SHA1.hexdigest(diagram_text)}"
        @diagram_cache.compute_if_absent(cache_key) do
          response = connection.get("#{language}/svg/#{encode_diagram(diagram_text)}")
          validate_content_type(response)
          sanitise_diagram(response.body)
        rescue Faraday::BadRequestError => e
          kroki_message = e.response_body.to_s.strip
          raise e, (kroki_message.empty? ? e.message : kroki_message)
        end
      end

      # Validates that the Kroki response has the expected SVG content type.
      #
      # @param [Faraday::Response] The response to validate.
      def validate_content_type(response)
        expected_content_type = "image/svg+xml"
        returned_content_type = response.headers[:content_type]
        return if returned_content_type == expected_content_type

        raise "[jekyll-kroki] Kroki returned an incorrect content type: " \
              "expected '#{expected_content_type}', received '#{returned_content_type}'"
      end

      # Sanitises a rendered diagram. Only <script> elements are removed, which is the most minimal / naive
      # implementation possible.
      #
      # @param [String] The diagram to sanitise in SVG format.
      # @return [String] The sanitised diagram.
      def sanitise_diagram(diagram_svg)
        parsed_svg = Nokogiri::XML(diagram_svg)
        parsed_svg.xpath('//*[name()="script"]').each(&:remove)
        parsed_svg.to_xml
      end

      # Encodes the diagram into Kroki format using deflate + base64.
      # See https://docs.kroki.io/kroki/setup/encode-diagram/.
      #
      # @param [String] The diagram description to encode.
      # @return [String] The encoded diagram.
      def encode_diagram(diagram_desc)
        Base64.urlsafe_encode64(Zlib.deflate(diagram_desc, Zlib::BEST_COMPRESSION))
      end

      # Sets up a new Faraday connection.
      #
      # @param [URI::HTTP] The URL of the Kroki instance.
      # @param [Integer] The number of retries.
      # @param [Integer] The timeout value in seconds.
      # @return [Faraday::Connection] The Faraday connection.
      def setup_connection(kroki_url, retries, timeout)
        retry_options = { max: retries, interval: HTTP_RETRY_INTERVAL,
                          interval_randomness: HTTP_RETRY_INTERVAL_RANDOMNESS,
                          backoff_factor: HTTP_RETRY_INTERVAL_BACKOFF_FACTOR,
                          exceptions: [Faraday::RequestTimeoutError, Faraday::ServerError] }

        Faraday.new(url: kroki_url, request: { timeout: timeout }) do |builder|
          builder.adapter :httpx, persistent: true
          builder.request :retry, retry_options
          builder.response :json, content_type: /\bjson$/
          builder.response :raise_error
        end
      end

      # Determines whether a document may contain embeddable diagram descriptions; it is in HTML format and is either
      # a Jekyll::Page or writeable Jekyll::Document.
      #
      # @param [Jekyll::Page or Jekyll::Document] The document to check for embeddable diagrams.
      def embeddable?(doc)
        doc.output_ext == ".html" && (doc.is_a?(Jekyll::Page) || doc.write?)
      end
    end
  end
end

Jekyll::Hooks.register :site, :post_render do |site|
  Jekyll::Kroki.embed_site(site)
rescue StandardError => e
  Jekyll.logger.error "[jekyll-kroki] #{e.class}: #{e.message}"
  raise
end
