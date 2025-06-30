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
    KROKI_DEFAULT_URL = "https://kroki.io"
    SUPPORTED_LANGUAGES = %w[actdiag blockdiag bpmn bytefield c4plantuml d2 dbml diagramsnet ditaa erd excalidraw
                             graphviz mermaid nomnoml nwdiag packetdiag pikchr plantuml rackdiag seqdiag structurizr
                             svgbob symbolator tikz umlet vega vegalite wavedrom wireviz].freeze
    EXPECTED_HTML_TAGS = %w[code div].freeze
    HTTP_MAX_RETRIES = 3
    HTTP_RETRY_INTERVAL_BACKOFF_FACTOR = 2
    HTTP_RETRY_INTERVAL_RANDOMNESS = 0.5
    HTTP_RETRY_INTERVAL_SECONDS = 0.1
    HTTP_TIMEOUT_SECONDS = 15
    MAX_CONCURRENT_DOCS = 10

    class << self
      # Renders and embeds all diagram descriptions in the given Jekyll site using Kroki.
      #
      # @param [Jekyll::Site] The Jekyll site to embed diagrams in.
      def embed_site(site)
        kroki_url = kroki_url(site.config)
        connection = setup_connection(kroki_url)

        rendered_diag = embed_docs_in_site(site, connection)
        unless rendered_diag.zero?
          puts "[jekyll-kroki] Rendered #{rendered_diag} diagrams using Kroki instance at '#{kroki_url}'"
        end
      rescue StandardError => e
        exit(e)
      end

      # Renders the diagram descriptions in all Jekyll pages and documents in the given Jekyll site. Pages / documents
      # are rendered concurrently up to the limit defined by MAX_CONCURRENT_DOCS.
      #
      # @param [Jekyll::Site] The Jekyll site to embed diagrams in.
      # @param [Faraday::Connection] The Faraday connection to use.
      # @return [Integer] The number of successfully rendered diagrams.
      def embed_docs_in_site(site, connection)
        rendered_diag = 0
        semaphore = Async::Semaphore.new(MAX_CONCURRENT_DOCS)

        Async do |task|
          tasks = (site.pages + site.documents).map do |doc|
            next unless embeddable?(doc)

            async_embed_single_doc(task, semaphore, connection, doc)
          end.compact

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
      # @return [Faraday::Connection] The Faraday connection.
      def setup_connection(kroki_url)
        retry_options = { max: HTTP_MAX_RETRIES, interval: HTTP_RETRY_INTERVAL_SECONDS,
                          interval_randomness: HTTP_RETRY_INTERVAL_RANDOMNESS,
                          backoff_factor: HTTP_RETRY_INTERVAL_BACKOFF_FACTOR,
                          exceptions: [Faraday::RequestTimeoutError, Faraday::ServerError] }

        Faraday.new(url: kroki_url, request: { timeout: HTTP_TIMEOUT_SECONDS }) do |builder|
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
      def kroki_url(config)
        if config.key?("kroki") && config["kroki"].key?("url")
          url = config["kroki"]["url"]
          raise TypeError, "'url' is not a valid HTTP URL" unless URI.parse(url).is_a?(URI::HTTP)
        else
          url = KROKI_DEFAULT_URL
        end
        URI(url)
      end

      # Determines whether a document may contain embeddable diagram descriptions - it is in HTML format and is either
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
