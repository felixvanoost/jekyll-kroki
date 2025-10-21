# frozen_string_literal: true

require_relative "kroki/version"

require "async"
require "async/semaphore"
require "base64"
require "faraday"
require "faraday/retry"
require "httpx/adapters/faraday"
require "jekyll"
require "nokogiri"
require "zlib"

module Jekyll
  # Converts diagram descriptions into images using Kroki.
  class Kroki
    DEFAULT_KROKI_URL = "https://kroki.io"
    DEFAULT_HTTP_RETRIES = 3
    DEFAULT_HTTP_TIMEOUT = 15
    DEFAULT_MAX_CONCURRENT_DOCS = 8
    EXPECTED_HTML_TAGS = %w[code div].freeze
    HTTP_RETRY_INTERVAL_BACKOFF_FACTOR = 2
    HTTP_RETRY_INTERVAL_RANDOMNESS = 0.5
    HTTP_RETRY_INTERVAL = 0.1
    SUPPORTED_LANGUAGES = %w[actdiag blockdiag bpmn bytefield c4plantuml d2 dbml diagramsnet ditaa erd excalidraw
                             graphviz mermaid nomnoml nwdiag packetdiag pikchr plantuml rackdiag seqdiag structurizr
                             svgbob symbolator tikz umlet vega vegalite wavedrom wireviz].freeze

    class << self
      # Renders and embeds all diagram descriptions in the given Jekyll site using Kroki.
      #
      # @param [Jekyll::Site] The Jekyll site to embed diagrams in.
      def embed_site(site)
        kroki_url = get_kroki_url(site.config)
        http_retries = get_http_retries(site.config)
        http_timeout = get_http_timeout(site.config)
        connection = setup_connection(kroki_url, http_retries, http_timeout)

        max_concurrent_docs = get_max_concurrent_docs(site.config)
        rendered_diag = embed_docs_in_site(site, connection, max_concurrent_docs)
        unless rendered_diag.zero?
          puts "[jekyll-kroki] Rendered #{rendered_diag} diagrams using Kroki instance at '#{kroki_url}'"
        end
      rescue StandardError => e
        exit(e)
      end

      # Renders the diagram descriptions in all Jekyll pages and documents in the given Jekyll site. Pages / documents
      # are rendered concurrently up to the limit defined by DEFAULT_MAX_CONCURRENT_DOCS.
      #
      # @param [Jekyll::Site] The Jekyll site to embed diagrams in.
      # @param [Faraday::Connection] The Faraday connection to use.
      # @param [Integer] The maximum number of documents to render concurrently.
      # @return [Integer] The number of successfully rendered diagrams.
      def embed_docs_in_site(site, connection, max_concurrent_docs)
        rendered_diag = 0
        semaphore = Async::Semaphore.new(max_concurrent_docs)

        Async do |task|
          tasks = (site.pages + site.documents).filter_map do |doc|
            next unless embeddable?(doc)

            async_embed_single_doc(task, semaphore, connection, doc)
          end

          rendered_diag = tasks.sum(&:wait)
        end

        rendered_diag
      end

      # Renders the supported diagram descriptions in a single document asynchronously, respecting the concurrency limit
      # imposed by the provided semaphore.
      #
      # @param [Async::Task] The parent async task to spawn a child task from.
      # @param [Async::Semaphore] A semaphore to limit concurrency.
      # @param [Faraday::Connection] The Faraday connection to use.
      # @param [Jekyll::Page, Jekyll::Document] The document to process.
      # @return [Integer] The number of successfully rendered diagrams.
      def async_embed_single_doc(task, semaphore, connection, doc)
        task.async do
          semaphore.async { embed_single_doc(connection, doc) }.wait
        rescue StandardError => e
          warn "[jekyll-kroki] Error rendering diagram: #{e.message}".red
          0
        end
      end

      # Renders the supported diagram descriptions in a single document and embeds them as inline SVGs in the HTML
      # source.
      #
      # @param [Faraday::Connection] The Faraday connection to use.
      # @param [Jekyll::Page, Jekyll::Document] The document to process.
      # @return [Integer] The number of successfully rendered diagrams.
      def embed_single_doc(connection, doc)
        # Parse the HTML document.
        parsed_doc = Nokogiri::HTML(doc.output)

        rendered_diag = 0
        SUPPORTED_LANGUAGES.each do |language|
          EXPECTED_HTML_TAGS.each do |tag|
            parsed_doc.css("#{tag}[class~='language-#{language}']").each do |diagram_desc|
              # Replace the diagram description with the SVG representation rendered by Kroki.
              diagram_desc.replace(render_diagram(connection, diagram_desc, language))
              rendered_diag += 1
            end
          end
        end

        # Convert the document back to HTML.
        doc.output = parsed_doc.to_html
        rendered_diag
      end

      # Renders a single diagram description using Kroki.
      #
      # @param [Faraday::Connection] The Faraday connection to use.
      # @param [String] The diagram description.
      # @param [String] The language of the diagram description.
      # @return [String] The rendered diagram in SVG format.
      def render_diagram(connection, diagram_desc, language)
        begin
          response = connection.get("#{language}/svg/#{encode_diagram(diagram_desc.text)}")
        rescue Faraday::Error => e
          raise e.message
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
      # implementation possible.
      #
      # @param [String] The diagram to santise in SVG format.
      # @return [String] The sanitised diagram.
      def sanitise_diagram(diagram_svg)
        parsed_svg = Nokogiri::XML(diagram_svg)
        parsed_svg.xpath('//*[name()="script"]').each(&:remove)
        parsed_svg.to_xml
      end

      # Encodes the diagram into Kroki format using deflate + base64.
      # See https://docs.kroki.io/kroki/setup/encode-diagram/.
      #
      # @param [String, #read] The diagram description to encode.
      # @return [String] The encoded diagram.
      def encode_diagram(diagram_desc)
        Base64.urlsafe_encode64(Zlib.deflate(diagram_desc))
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

      # Gets the URL of the Kroki instance to use for rendering diagrams.
      #
      # @param The Jekyll site configuration.
      # @return [URI::HTTP] The URL of the Kroki instance.
      def get_kroki_url(config)
        url = config.fetch("kroki", {}).fetch("url", DEFAULT_KROKI_URL)
        raise TypeError, "'url' is not a valid HTTP URL" unless URI.parse(url).is_a?(URI::HTTP)

        URI(url)
      end

      # Gets the number of HTTP retries.
      #
      # @param The Jekyll site configuration.
      # @return [Integer] The number of HTTP retries.
      def get_http_retries(config)
        config.fetch("kroki", {}).fetch("http_retries", DEFAULT_HTTP_RETRIES)
      end

      # Gets the HTTP timeout value.
      #
      # @param The Jekyll site configuration.
      # @return [Integer] The HTTP timeout value in seconds.
      def get_http_timeout(config)
        config.fetch("kroki", {}).fetch("http_timeout", DEFAULT_HTTP_TIMEOUT)
      end

      # Gets the maximum number of documents to render concurrently.
      #
      # @param The Jekyll site configuration.
      # @return [Integer] The maximum number of documents to render concurrently.
      def get_max_concurrent_docs(config)
        config.fetch("kroki", {}).fetch("max_concurrent_docs", DEFAULT_MAX_CONCURRENT_DOCS)
      end

      # Determines whether a document may contain embeddable diagram descriptions; it is in HTML format and is either
      # a Jekyll::Page or writeable Jekyll::Document.
      #
      # @param [Jekyll::Page or Jekyll::Document] The document to check for embeddability.
      def embeddable?(doc)
        doc.output_ext == ".html" && (doc.is_a?(Jekyll::Page) || doc.write?)
      end

      # Exits the Jekyll process without returning a stack trace. This method does not return because the process is
      # abruptly terminated.
      #
      # @param [StandardError] The error to display in the termination message.
      # @param [int] The caller index to display in the termination message. The default index is 1, which means the
      #              calling method. To specify the calling method's caller, pass in 2.
      #
      # Source: https://www.mslinn.com/ruby/2200-crash-exit.html
      def exit(error, caller_index = 1)
        raise error
      rescue StandardError => e
        file, line_number, caller = e.backtrace[caller_index].split(":")
        caller = caller.tr("", "'")
        warn %([jekyll-kroki] "#{error.message}" #{caller} on line #{line_number} of #{file}).red
        exec "exit 1"
      end
    end
  end
end

Jekyll::Hooks.register :site, :post_render do |site|
  Jekyll::Kroki.embed_site(site)
end
