# frozen_string_literal: true

require "test_helper"
require "jekyll"
require "jekyll/kroki"
require "faraday"
require "nokogiri"
require "base64"
require "zlib"

module Jekyll
  class TestKrokiUrl < Minitest::Test
    def test_valid_kroki_url
      url = "https://rubygems.org/"
      config = { "kroki" => { "url" => url } }
      assert_equal ::Jekyll::Kroki.kroki_url(config), URI(url)
    end

    def test_invalid_kroki_url
      url = "ht//rubygems.org/"
      config = { "kroki" => { "url" => url } }
      assert_raises(TypeError) { ::Jekyll::Kroki.kroki_url(config) }
    end

    def test_missing_kroki_url
      config = { "kroki" => { "pi" => 3.14 } }
      assert_equal ::Jekyll::Kroki.kroki_url(config), URI("https://kroki.io")
    end

    def test_missing_kroki_config
      config = { "another-plugin" => { "pi" => 3.14 } }
      assert_equal ::Jekyll::Kroki.kroki_url(config), URI("https://kroki.io")
    end
  end

  class TestKrokiEmbeddable < Minitest::Test
    def test_embeddable_document
      doc = Minitest::Mock.new
      doc.expect(:output_ext, ".html")
      doc.expect(:is_a?, true, [Jekyll::Page])
      assert ::Jekyll::Kroki.embeddable?(doc)
      doc.verify
    end

    def test_non_embeddable_document
      doc = Minitest::Mock.new
      doc.expect(:output_ext, ".md")
      refute ::Jekyll::Kroki.embeddable?(doc)
      doc.verify
    end

    def test_non_html_embeddable_document
      doc = Minitest::Mock.new
      doc.expect(:output_ext, ".html")
      doc.expect(:is_a?, false, [Jekyll::Page]) # Simulate that it's not a Jekyll::Page
      doc.expect(:write?, false) # The document cannot be written, so it's not embeddable

      refute ::Jekyll::Kroki.embeddable?(doc) # Expecting false (non-embeddable document)
      doc.verify
    end
  end

  class TestKrokiUtils < Minitest::Test
    def test_setup_connection
      kroki_url = "https://kroki.io"
      connection = ::Jekyll::Kroki.setup_connection(kroki_url)
      assert_instance_of Faraday::Connection, connection
    end

    def test_encode_diagram
      diagram_desc = "graph TD; A-->B;"
      encoded = ::Jekyll::Kroki.encode_diagram(diagram_desc)
      assert_instance_of String, encoded
    end

    def test_sanitise_diagram
      diagram_svg = '<?xml version="1.0"?><svg><script>alert("test")</script></svg>'
      sanitised = ::Jekyll::Kroki.sanitise_diagram(diagram_svg)
      assert_equal "<?xml version=\"1.0\"?>\n<svg/>\n", sanitised
    end
  end

  class TestKrokiRendering < Minitest::Test
    def setup
      @connection = Minitest::Mock.new
    end

    def test_render_diagram_success
      diagram_desc = Minitest::Mock.new
      diagram_text = "graph TD; A-->B;"
      diagram_desc.expect(:text, diagram_text)

      response = Minitest::Mock.new
      response.expect(:headers, { content_type: "image/svg+xml" })
      response.expect(:body, "<?xml version=\"1.0\"?>\n<svg/>\n")

      encoded_diagram = Base64.urlsafe_encode64(Zlib.deflate(diagram_text))
      @connection.expect(:get, response, ["mermaid/svg/#{encoded_diagram}"])

      result = ::Jekyll::Kroki.render_diagram(@connection, diagram_desc, "mermaid")
      assert_equal "<?xml version=\"1.0\"?>\n<svg/>\n", result

      @connection.verify
    end

    def test_render_diagram_failure
      diagram_desc = Minitest::Mock.new
      diagram_desc.expect(:text, "graph TD; A-->B;")
      @connection.expect(:get, nil) { raise "Connection failed" }

      assert_raises(RuntimeError) do
        ::Jekyll::Kroki.render_diagram(@connection, diagram_desc, "mermaid")
      end

      @connection.verify
    end

    def test_render_diagram_incorrect_content_type
      diagram_desc = Minitest::Mock.new
      diagram_desc.expect(:text, "graph TD; A-->B;")
      response = Minitest::Mock.new
      response.expect(:headers, { content_type: "text/html" })
      response.expect(:body, "<?xml version=\"1.0\"?>\n<svg/>\n")

      encoded_diagram = Base64.urlsafe_encode64(Zlib.deflate("graph TD; A-->B;"))
      @connection.expect(:get, response, ["mermaid/svg/#{encoded_diagram}"])

      assert_raises(RuntimeError) do
        ::Jekyll::Kroki.render_diagram(@connection, diagram_desc, "mermaid")
      end

      @connection.verify
    end
  end

  class TestKrokiEmbed < Minitest::Test
    def setup
      @connection = Minitest::Mock.new
    end

    def test_embed_single_doc
      doc = Minitest::Mock.new
      doc.expect(:output, "<div class='language-mermaid'>graph TD; A-->B;</div>")
      doc.expect(:output=, nil, [String])

      response = Minitest::Mock.new
      response.expect(:headers, { content_type: "image/svg+xml" })
      response.expect(:body, "<?xml version=\"1.0\"?>\n<svg/>\n")

      encoded_diagram = Base64.urlsafe_encode64(Zlib.deflate("graph TD; A-->B;"))
      @connection.expect(:get, response, ["mermaid/svg/#{encoded_diagram}"])

      rendered_diag = ::Jekyll::Kroki.embed_single_doc(@connection, doc)
      assert_equal 1, rendered_diag

      @connection.verify
    end

    def test_embed_site
      site = setup_mock_site
      connection = setup_mock_connection

      # Ensure the expected arguments match exactly what is being called
      response = setup_mock_response("graph TD; A-->B;")
      encoded_diagram = Base64.urlsafe_encode64(Zlib.deflate("graph TD; A-->B;"))
      connection.expect(:get, response, ["mermaid/svg/#{encoded_diagram}"])

      ::Jekyll::Kroki.stub(:setup_connection, connection) do
        ::Jekyll::Kroki.embed_site(site)
      end

      verify_mocks(site, connection)
    end

    private

    def setup_mock_site
      site = Minitest::Mock.new
      config = { "kroki" => { "url" => "https://kroki.io" } }
      site.expect(:config, config)

      doc = Minitest::Mock.new
      doc.expect(:output_ext, ".html")
      doc.expect(:is_a?, false, [Jekyll::Page])
      doc.expect(:write?, true)
      doc.expect(:output, "<div class='language-mermaid'>graph TD; A-->B;</div>")
      doc.expect(:output=, nil, [String])

      site.expect(:pages, [])
      site.expect(:documents, [doc])
      site
    end

    def setup_mock_connection
      Minitest::Mock.new
    end

    def setup_mock_response(_diagram_text)
      response = Minitest::Mock.new
      response.expect(:headers, { content_type: "image/svg+xml" })
      response.expect(:body, "<?xml version=\"1.0\"?>\n<svg/>\n")
      response
    end

    def setup_mock_site_and_connection
      site = Minitest::Mock.new
      config = { "kroki" => { "url" => "https://kroki.io" } }
      site.expect(:config, config)

      pages = [setup_mock_page("graph TD; A-->B;"), setup_mock_page("graph TD; C-->D;")]
      documents = [setup_mock_doc("graph TD; E-->F;"), setup_mock_doc("graph TD; G-->H;")]

      site.expect(:pages, pages)
      site.expect(:documents, documents)

      connection = Minitest::Mock.new
      [site, connection]
    end

    def setup_mock_page(diagram_text)
      page = Minitest::Mock.new
      page.expect(:output_ext, ".html")
      page.expect(:is_a?, true, [Jekyll::Page])
      page.expect(:output, "<div class='language-mermaid'>#{diagram_text}</div>")
      page.expect(:output=, nil, [String])
      page
    end

    def setup_mock_doc(diagram_text)
      doc = Minitest::Mock.new
      doc.expect(:output_ext, ".html")
      doc.expect(:is_a?, false, [Jekyll::Page])
      doc.expect(:write?, true)
      doc.expect(:output, "<div class='language-mermaid'>#{diagram_text}</div>")
      doc.expect(:output=, nil, [String])
      doc
    end

    def setup_mock_responses(connection)
      ["A-->B", "C-->D", "E-->F", "G-->H"].each do |diagram_text|
        response = Minitest::Mock.new
        response.expect(:headers, { content_type: "image/svg+xml" })
        response.expect(:body, "<?xml version=\"1.0\"?>\n<svg>#{diagram_text}</svg>\n")
        encoded_diagram = Base64.urlsafe_encode64(Zlib.deflate("graph TD; #{diagram_text};"))
        connection.expect(:get, response, ["mermaid/svg/#{encoded_diagram}"])
      end
    end

    def verify_mocks(site, connection)
      site.verify
      connection.verify
    end

    def capture_output
      output = StringIO.new
      $stdout = output
      yield
      $stdout = STDOUT
      output.string
    end
  end
end
