# frozen_string_literal: true

require "test_helper"
require "jekyll"
require "jekyll/kroki"
require "faraday"
require "nokogiri"
require "base64"
require "zlib"

module Jekyll
  class TestKrokiConfig < Minitest::Test
    def test_valid_kroki_url
      url = "https://rubygems.org/"
      config = { "kroki" => { "url" => url } }

      assert_equal URI(url), Jekyll::Kroki::Config.new(config).kroki_url
    end

    def test_invalid_kroki_url
      config = { "kroki" => { "url" => "not a uri at all" } }

      assert_raises(URI::InvalidURIError) { Jekyll::Kroki::Config.new(config) }
    end

    def test_non_http_kroki_url
      config = { "kroki" => { "url" => "ftp://rubygems.org/" } }

      assert_raises(TypeError) { Jekyll::Kroki::Config.new(config) }
    end

    def test_missing_kroki_url
      config = { "kroki" => { "pi" => 3.14 } }

      assert_equal URI("https://kroki.io"), Jekyll::Kroki::Config.new(config).kroki_url
    end

    def test_missing_kroki_config
      config = { "another-plugin" => { "pi" => 3.14 } }

      assert_equal URI("https://kroki.io"), Jekyll::Kroki::Config.new(config).kroki_url
    end

    # --- http_retries ---

    def test_valid_http_retries
      retries = 5
      config = { "kroki" => { "http_retries" => retries } }

      assert_equal retries, Jekyll::Kroki::Config.new(config).http_retries
    end

    def test_default_http_retries
      config = {}

      assert_equal Jekyll::Kroki::Config::DEFAULT_HTTP_RETRIES, Jekyll::Kroki::Config.new(config).http_retries
    end

    def test_zero_http_retries
      config = { "kroki" => { "http_retries" => 0 } }

      assert_equal 0, Jekyll::Kroki::Config.new(config).http_retries
    end

    def test_negative_http_retries
      config = { "kroki" => { "http_retries" => -1 } }

      assert_raises(ArgumentError) { Jekyll::Kroki::Config.new(config) }
    end

    def test_non_integer_http_retries
      config = { "kroki" => { "http_retries" => "3" } }

      assert_raises(TypeError) { Jekyll::Kroki::Config.new(config) }
    end

    # --- http_timeout ---

    def test_valid_http_timeout
      timeout = 30
      config = { "kroki" => { "http_timeout" => timeout } }

      assert_equal timeout, Jekyll::Kroki::Config.new(config).http_timeout
    end

    def test_default_http_timeout
      config = {}

      assert_equal Jekyll::Kroki::Config::DEFAULT_HTTP_TIMEOUT, Jekyll::Kroki::Config.new(config).http_timeout
    end

    def test_zero_http_timeout_is_valid
      config = { "kroki" => { "http_timeout" => 0 } }

      assert_equal 0, Jekyll::Kroki::Config.new(config).http_timeout
    end

    def test_negative_http_timeout_raises
      config = { "kroki" => { "http_timeout" => -1 } }

      assert_raises(ArgumentError) { Jekyll::Kroki::Config.new(config) }
    end

    def test_non_integer_http_timeout_raises
      config = { "kroki" => { "http_timeout" => 15.5 } }

      assert_raises(TypeError) { Jekyll::Kroki::Config.new(config) }
    end

    # --- max_concurrent_docs ---

    def test_valid_max_concurrent_docs
      max_concurrent = 4
      config = { "kroki" => { "max_concurrent_docs" => max_concurrent } }

      assert_equal max_concurrent, Jekyll::Kroki::Config.new(config).max_concurrent_docs
    end

    def test_default_max_concurrent_docs
      config = {}

      assert_equal Jekyll::Kroki::Config::DEFAULT_MAX_CONCURRENT_DOCS,
                   Jekyll::Kroki::Config.new(config).max_concurrent_docs
    end

    def test_zero_max_concurrent_docs_raises
      config = { "kroki" => { "max_concurrent_docs" => 0 } }

      assert_raises(ArgumentError) { Jekyll::Kroki::Config.new(config) }
    end

    def test_negative_max_concurrent_docs_raises
      config = { "kroki" => { "max_concurrent_docs" => -2 } }

      assert_raises(ArgumentError) { Jekyll::Kroki::Config.new(config) }
    end

    def test_non_integer_max_concurrent_docs_raises
      config = { "kroki" => { "max_concurrent_docs" => "8" } }

      assert_raises(TypeError) { Jekyll::Kroki::Config.new(config) }
    end

    # --- immutability ---

    def test_config_is_frozen
      assert_predicate Jekyll::Kroki::Config.new({}), :frozen?
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

  class TestKrokiValidateContentType < Minitest::Test
    def test_valid_content_type
      response = Minitest::Mock.new
      response.expect(:headers, { content_type: "image/svg+xml" })

      assert_nil ::Jekyll::Kroki.validate_content_type(response)
      response.verify
    end

    def test_invalid_content_type
      response = Minitest::Mock.new
      response.expect(:headers, { content_type: "text/html" })

      error = assert_raises(RuntimeError) { ::Jekyll::Kroki.validate_content_type(response) }
      assert_match "image/svg+xml", error.message
      assert_match "text/html", error.message
      response.verify
    end

    def test_missing_content_type
      response = Minitest::Mock.new
      response.expect(:headers, {})

      assert_raises(RuntimeError) { ::Jekyll::Kroki.validate_content_type(response) }
      response.verify
    end

    def test_content_type_with_charset_suffix
      response = Minitest::Mock.new
      response.expect(:headers, { content_type: "image/svg+xml; charset=utf-8" })

      assert_raises(RuntimeError) { ::Jekyll::Kroki.validate_content_type(response) }
      response.verify
    end
  end

  class TestKrokiRendering < Minitest::Test
    def setup
      @connection = Minitest::Mock.new
      # Reset the diagram cache before each test so that cached results from a previous
      # test do not affect the next one.
      ::Jekyll::Kroki.instance_variable_set(:@diagram_cache, Concurrent::Map.new)
    end

    def test_render_diagram_success
      diagram_text = "graph TD; A-->B;"
      diagram_desc = diagram_desc_mock(diagram_text)
      response = svg_response

      @connection.expect(:get, response, ["mermaid/svg/#{encode(diagram_text)}"])

      result = ::Jekyll::Kroki.render_diagram(@connection, diagram_desc, "mermaid")

      assert_equal "<?xml version=\"1.0\"?>\n<svg/>\n", result
      @connection.verify
    end

    def test_render_diagram_failure
      diagram_text = "graph TD; A-->B;"
      diagram_desc = diagram_desc_mock(diagram_text)
      @connection.expect(:get, nil) { raise "Connection failed" }

      assert_raises(RuntimeError) do
        ::Jekyll::Kroki.render_diagram(@connection, diagram_desc, "mermaid")
      end

      @connection.verify
    end

    def test_render_diagram_incorrect_content_type
      diagram_text = "graph TD; A-->B;"
      diagram_desc = diagram_desc_mock(diagram_text)
      response = Minitest::Mock.new
      response.expect(:headers, { content_type: "text/html" })
      response.expect(:body, "<?xml version=\"1.0\"?>\n<svg/>\n")

      @connection.expect(:get, response, ["mermaid/svg/#{encode(diagram_text)}"])

      assert_raises(RuntimeError) do
        ::Jekyll::Kroki.render_diagram(@connection, diagram_desc, "mermaid")
      end

      @connection.verify
    end

    def test_render_diagram_is_cached_after_first_call
      diagram_text = "graph TD; A-->B;"
      desc_first  = diagram_desc_mock(diagram_text)
      desc_second = diagram_desc_mock(diagram_text)
      @connection.expect(:get, svg_response, ["mermaid/svg/#{encode(diagram_text)}"])

      first_result  = ::Jekyll::Kroki.render_diagram(@connection, desc_first,  "mermaid")
      second_result = ::Jekyll::Kroki.render_diagram(@connection, desc_second, "mermaid")

      assert_equal first_result, second_result
      # Verifying the mock ensures :get was called exactly once — a second call
      # would raise a MockExpectationError because no further :get is expected.
      @connection.verify
      desc_first.verify
      desc_second.verify
    end

    def test_cache_is_keyed_per_language
      diagram_text = "graph TD; A-->B;"
      encoded = encode(diagram_text)
      desc_mermaid  = diagram_desc_mock(diagram_text)
      desc_graphviz = diagram_desc_mock(diagram_text)
      @connection.expect(:get, svg_response("mermaid"),  ["mermaid/svg/#{encoded}"])
      @connection.expect(:get, svg_response("graphviz"), ["graphviz/svg/#{encoded}"])

      mermaid_result  = ::Jekyll::Kroki.render_diagram(@connection, desc_mermaid,  "mermaid")
      graphviz_result = ::Jekyll::Kroki.render_diagram(@connection, desc_graphviz, "graphviz")

      refute_equal mermaid_result, graphviz_result
      @connection.verify
    end

    def test_cache_is_keyed_per_diagram_text
      text_a = "graph TD; A-->B;"
      text_b = "graph TD; X-->Y;"
      desc_a = diagram_desc_mock(text_a)
      desc_b = diagram_desc_mock(text_b)
      @connection.expect(:get, svg_response("a"), ["mermaid/svg/#{encode(text_a)}"])
      @connection.expect(:get, svg_response("b"), ["mermaid/svg/#{encode(text_b)}"])

      result_a = ::Jekyll::Kroki.render_diagram(@connection, desc_a, "mermaid")
      result_b = ::Jekyll::Kroki.render_diagram(@connection, desc_b, "mermaid")

      refute_equal result_a, result_b
      @connection.verify
    end

    private

    def diagram_desc_mock(text)
      desc = Minitest::Mock.new
      desc.expect(:text, text)
      desc
    end

    def svg_response(id = nil)
      svg_body = if id
                   "<?xml version=\"1.0\"?>\n<svg id='#{id}'/>\n"
                 else
                   "<?xml version=\"1.0\"?>\n<svg/>\n"
                 end
      response = Minitest::Mock.new
      response.expect(:headers, { content_type: "image/svg+xml" })
      response.expect(:body, svg_body)
      response
    end

    def encode(text)
      Base64.urlsafe_encode64(Zlib.deflate(text))
    end
  end

  class TestKrokiEmbed < Minitest::Test
    def setup
      @connection = Minitest::Mock.new
      ::Jekyll::Kroki.instance_variable_set(:@diagram_cache, Concurrent::Map.new)
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
      connection = Minitest::Mock.new

      response = setup_mock_response
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

    def test_embed_site_uses_cache_across_docs
      diagram_text = "graph TD; A-->B;"
      site, connection = setup_two_doc_site(diagram_text)

      ::Jekyll::Kroki.stub(:setup_connection, connection) do
        ::Jekyll::Kroki.embed_site(site)
      end

      site.verify
      connection.verify
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

    def create_mock_doc(diagram_text)
      doc = Minitest::Mock.new
      doc.expect(:output_ext, ".html")
      doc.expect(:is_a?, false, [Jekyll::Page])
      doc.expect(:write?, true)
      doc.expect(:output, "<div class='language-mermaid'>#{diagram_text}</div>")
      doc.expect(:output=, nil, [String])
      doc
    end

    def setup_two_doc_site(diagram_text)
      encoded = Base64.urlsafe_encode64(Zlib.deflate(diagram_text))

      site = Minitest::Mock.new
      config = { "kroki" => { "url" => "https://kroki.io" } }
      site.expect(:config, config)
      site.expect(:pages, [])
      site.expect(:documents, [create_mock_doc(diagram_text), create_mock_doc(diagram_text)])

      connection = Minitest::Mock.new
      response = Minitest::Mock.new
      response.expect(:headers, { content_type: "image/svg+xml" })
      response.expect(:body, "<?xml version=\"1.0\"?>\n<svg/>\n")
      connection.expect(:get, response, ["mermaid/svg/#{encoded}"])

      [site, connection]
    end

    def setup_mock_response
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
