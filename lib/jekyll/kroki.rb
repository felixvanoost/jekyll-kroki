# frozen_string_literal: true

require_relative "kroki/version"

require "base64"
require "jekyll"
require "json"
require "net/http"
require "nokogiri"
require "zlib"

module Jekyll
  # Jekyll plugin for the Kroki diagram engine
  class Kroki
    KROKI_INSTANCE_URL = "https://kroki.io"

    class << self
      # Renders all diagram descriptions written in a Kroki-supported language in an HTML document.
      #
      # @param [Jekyll::Page or Jekyll::Document] The document to render diagrams in
      def render(doc)
        puts "Rendering diagrams using Kroki"

        # Parse the HTML document
        parsed_doc = Nokogiri::HTML.parse(doc.output)

        # Iterate through every diagram description in each of the supported languages
        get_supported_languages(KROKI_INSTANCE_URL).each do |language|
          parsed_doc.css("code[class~='language-#{language}']").each do |diagram_desc|
            # Get the rendered diagram using Kroki
            rendered_diagram = render_diagram(KROKI_INSTANCE_URL, diagram_desc, language)

            # Replace the diagram description with the SVG representation
            diagram_desc.replace(rendered_diagram)
          end
        end

        # Generate the modified HTML document
        doc.output = parsed_doc.to_html
      end

      # Renders a diagram description using Kroki.
      #
      # @param [String] The URL of the Kroki instance
      # @param [String] The diagram description
      # @param [String] The language of the diagram description
      # @return [String] The rendered diagram in SVG format
      def render_diagram(kroki_url, diagram_desc, language)
        # Encode the diagram and construct the URI
        uri = URI("#{kroki_url}/#{language}/svg/#{encode_diagram(diagram_desc.text)}")

        begin
          response = Net::HTTP.get_response(uri)
        rescue StandardError => e
          raise e.message
        else
          response.body if response.is_a?(Net::HTTPSuccess)
        end
      end

      # Encodes the diagram into Kroki format using deflate + base64.
      # See https://docs.kroki.io/kroki/setup/encode-diagram/.
      #
      # @param [String, #read] The diagram to encode
      # @return [String] The encoded diagram
      def encode_diagram(diagram)
        Base64.urlsafe_encode64(Zlib.deflate(diagram))
      end

      # Gets an array of supported diagram languages from the Kroki '/health' endpoint.
      #
      # This only shows which languages the Kroki project supports, not which ones are currently available from the
      # configured Kroki instance. For example, Mermaid will still show up as a supported language even if the Mermaid
      # companion container is not running.
      #
      # @param [String] The URL of the Kroki instance
      # @return [Array] The supported diagram languages
      def get_supported_languages(kroki_url)
        uri = URI("#{kroki_url}/health")

        begin
          response = Net::HTTP.get_response(uri)
        rescue StandardError => e
          raise e.message
        else
          JSON.parse(response.body)["version"].keys if response.is_a?(Net::HTTPSuccess)
        end
      end

      # Determines whether a document may contain renderable diagram descriptions - it is in HTML format and is either
      # a Jekyll::Page or writeable Jekyll::Document.
      #
      # @param [Jekyll::Page or Jekyll::Document] The document to check for renderability
      def renderable?(doc)
        doc.output_ext == ".html" && (doc.is_a?(Jekyll::Page) || doc.write?)
      end
    end
  end
end

Jekyll::Hooks.register [:pages, :documents], :post_render do |doc|
  Jekyll::Kroki.render(doc) if Jekyll::Kroki.renderable?(doc)
end
