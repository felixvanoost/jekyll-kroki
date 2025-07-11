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

      assert_equal ::Jekyll::Kroki.get_kroki_url(config), URI(url)
    end

    def test_invalid_kroki_url
      url = "ht//rubygems.org/"
      config = { "kroki" => { "url" => url } }
      assert_raises(TypeError) { ::Jekyll::Kroki.get_kroki_url(config) }
    end

    def test_missing_kroki_url
      config = { "kroki" => { "pi" => 3.14 } }

      assert_equal ::Jekyll::Kroki.get_kroki_url(config), URI("https://kroki.io")
    end

    def test_missing_kroki_config
      config = { "another-plugin" => { "pi" => 3.14 } }

      assert_equal ::Jekyll::Kroki.get_kroki_url(config), URI("https://kroki.io")
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
      doc.expect(:is_a?, false, [Jekyll::Page])
      doc.expect(:write?, false)

      refute ::Jekyll::Kroki.embeddable?(doc)
      doc.verify
    end
  end

  class TestKrokiUtils < Minitest::Test
    def test_setup_connection
      kroki_url = "https://kroki.io"
      retries = 3
      timeout = 15
      connection = ::Jekyll::Kroki.setup_connection(kroki_url, retries, timeout)

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

      response = setup_mock_response("graph TD; A-->B;")
      encoded_diagram = Base64.urlsafe_encode64(Zlib.deflate("graph TD; A-->B;"))
      connection.expect(:get, response, ["mermaid/svg/#{encoded_diagram}"])

      ::Jekyll::Kroki.stub(:setup_connection, connection) do
        ::Jekyll::Kroki.embed_site(site)
      end

      verify_mocks(site, connection)
    end

    def test_embed_docs_concurrency_limit
      site = Minitest::Mock.new
      docs = Array.new(15) { |i| create_mock_doc("graph TD; A#{i}-->B#{i};") }
      site.expect(:pages, [])
      site.expect(:documents, docs)
      max_concurrent_docs = 8

      connection = Minitest::Mock.new
      call_count = 0

      Jekyll::Kroki.stub(:embed_single_doc, lambda { |_conn, _doc|
        call_count += 1
        1
      }) do
        Jekyll::Kroki.embed_docs_in_site(site, connection, max_concurrent_docs)
      end

      assert_equal 15, call_count
      site.verify
    end

    def test_embed_docs_handles_errors
      site = Minitest::Mock.new
      site.expect(:pages, [])
      bad_doc = create_mock_doc("fail")
      good_doc = create_mock_doc("graph TD; A-->B;")
      site.expect(:documents, [bad_doc, good_doc])
      max_concurrent_docs = 8

      connection = Minitest::Mock.new

      result = Jekyll::Kroki.stub(:embed_single_doc, lambda { |_conn, doc|
        doc.output.include?("fail") ? raise("bad!") : 1
      }) do
        Jekyll::Kroki.embed_docs_in_site(site, connection, max_concurrent_docs)
      end

      assert_equal 1, result
      site.verify
    end

    private

    def setup_mock_site
      site = Minitest::Mock.new
      config = { "kroki" => { "url" => "https://kroki.io" } }
      4.times { site.expect(:config, config) }

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

    def create_mock_doc(diagram_text)
      doc = Minitest::Mock.new
      doc.expect(:output_ext, ".html")
      doc.expect(:is_a?, false, [Jekyll::Page])
      doc.expect(:write?, true)
      doc.expect(:output, "<div class='language-mermaid'>#{diagram_text}</div>")
      doc.expect(:output=, nil, [String])
      doc
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

    def verify_mocks(site, connection)
      site.verify
      connection.verify
    end
  end
end
