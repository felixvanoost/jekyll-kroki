# frozen_string_literal: true

require "test_helper"
require "jekyll"
require "jekyll/kroki"
require "faraday"
require "nokogiri"
require "base64"
require "zlib"

module Jekyll
  module KrokiTestHelpers
    def encode(text)
      Base64.urlsafe_encode64(Zlib.deflate(text, Zlib::BEST_COMPRESSION))
    end

    def svg_response(id = nil)
      body = id ? "<?xml version=\"1.0\"?>\n<svg id='#{id}'/>\n" : "<?xml version=\"1.0\"?>\n<svg/>\n"
      response = Minitest::Mock.new
      response.expect(:headers, { content_type: "image/svg+xml" })
      response.expect(:body, body)
      response
    end

    def create_mock_doc(diagram_text, relative_path = "index.md")
      doc = Minitest::Mock.new
      doc.expect(:output_ext, ".html")
      doc.expect(:is_a?, false, [Jekyll::Page])
      doc.expect(:write?, true)
      doc.expect(:output, "<div class='language-mermaid'>#{diagram_text}</div>")
      doc.expect(:output=, nil, [String])
      doc.expect(:relative_path, relative_path)
      doc
    end
  end

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

    def test_https_kroki_url_is_accepted
      config = { "kroki" => { "url" => "https://kroki.example.com" } }

      assert_instance_of URI::HTTPS, Jekyll::Kroki::Config.new(config).kroki_url
    end

    def test_missing_kroki_url
      config = { "kroki" => { "pi" => 3.14 } }

      assert_equal URI("https://kroki.io"), Jekyll::Kroki::Config.new(config).kroki_url
    end

    def test_missing_kroki_config
      config = { "another-plugin" => { "pi" => 3.14 } }

      assert_equal URI("https://kroki.io"), Jekyll::Kroki::Config.new(config).kroki_url
    end

    def test_empty_site_config
      config = {}

      cfg = Jekyll::Kroki::Config.new(config)

      assert_equal URI("https://kroki.io"), cfg.kroki_url
      assert_equal Jekyll::Kroki::Config::DEFAULT_HTTP_RETRIES, cfg.http_retries
      assert_equal Jekyll::Kroki::Config::DEFAULT_HTTP_TIMEOUT, cfg.http_timeout
      assert_equal Jekyll::Kroki::Config::DEFAULT_MAX_CONCURRENT_DOCS, cfg.max_concurrent_docs
    end

    def test_valid_http_retries
      retries = 5
      config = { "kroki" => { "http_retries" => retries } }

      assert_equal retries, Jekyll::Kroki::Config.new(config).http_retries
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

    def test_valid_http_timeout
      timeout = 30
      config = { "kroki" => { "http_timeout" => timeout } }

      assert_equal timeout, Jekyll::Kroki::Config.new(config).http_timeout
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

    def test_valid_max_concurrent_docs
      max_concurrent = 4
      config = { "kroki" => { "max_concurrent_docs" => max_concurrent } }

      assert_equal max_concurrent, Jekyll::Kroki::Config.new(config).max_concurrent_docs
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

    def test_one_max_concurrent_docs_is_valid
      config = { "kroki" => { "max_concurrent_docs" => 1 } }

      assert_equal 1, Jekyll::Kroki::Config.new(config).max_concurrent_docs
    end

    def test_config_is_frozen
      assert_predicate Jekyll::Kroki::Config.new({}), :frozen?
    end
  end

  class TestKrokiEmbeddable < Minitest::Test
    def test_embeddable_jekyll_page
      doc = Minitest::Mock.new
      doc.expect(:output_ext, ".html")
      doc.expect(:is_a?, true, [Jekyll::Page])

      assert ::Jekyll::Kroki.embeddable?(doc)
      doc.verify
    end

    def test_non_embeddable_non_html_document
      doc = Minitest::Mock.new
      doc.expect(:output_ext, ".md")
      # output_ext returns ".md" so embeddable? short-circuits; is_a? must not be called.

      refute ::Jekyll::Kroki.embeddable?(doc)
      doc.verify
    end

    def test_non_writable_html_document_is_not_embeddable
      doc = Minitest::Mock.new
      doc.expect(:output_ext, ".html")
      doc.expect(:is_a?, false, [Jekyll::Page])
      doc.expect(:write?, false)

      refute ::Jekyll::Kroki.embeddable?(doc)
      doc.verify
    end

    def test_writable_html_document_is_embeddable
      doc = Minitest::Mock.new
      doc.expect(:output_ext, ".html")
      doc.expect(:is_a?, false, [Jekyll::Page])
      doc.expect(:write?, true)

      assert ::Jekyll::Kroki.embeddable?(doc)
      doc.verify
    end

    def test_non_html_jekyll_page_is_not_embeddable
      doc = Minitest::Mock.new
      doc.expect(:output_ext, ".xml")

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

    def test_encode_diagram_is_reversible
      diagram_desc = "graph TD; A-->B;"
      encoded = ::Jekyll::Kroki.encode_diagram(diagram_desc)

      assert_instance_of String, encoded
      decoded = Zlib.inflate(Base64.urlsafe_decode64(encoded))

      assert_equal diagram_desc, decoded
    end

    def test_sanitise_diagram_removes_script_tags
      diagram_svg = '<?xml version="1.0"?><svg><script>alert("test")</script></svg>'
      sanitised = ::Jekyll::Kroki.sanitise_diagram(diagram_svg)

      assert_equal "<?xml version=\"1.0\"?>\n<svg/>\n", sanitised
    end

    def test_sanitise_diagram_removes_nested_script_tags
      diagram_svg = '<?xml version="1.0"?><svg><g><script>evil()</script></g></svg>'
      sanitised = ::Jekyll::Kroki.sanitise_diagram(diagram_svg)

      refute_includes sanitised, "<script"
      refute_includes sanitised, "evil()"
    end
  end

  class TestKrokiValidateContentType < Minitest::Test
    def test_valid_content_type
      response = Minitest::Mock.new
      response.expect(:headers, { content_type: "image/svg+xml" })

      assert_nil ::Jekyll::Kroki.validate_content_type(response)
      response.verify
    end

    def test_invalid_content_type_error_message_names_both_types
      response = Minitest::Mock.new
      response.expect(:headers, { content_type: "text/html" })

      error = assert_raises(RuntimeError) { ::Jekyll::Kroki.validate_content_type(response) }
      assert_match "image/svg+xml", error.message
      assert_match "text/html", error.message
      response.verify
    end

    def test_missing_content_type_raises
      response = Minitest::Mock.new
      response.expect(:headers, {})

      assert_raises(RuntimeError) { ::Jekyll::Kroki.validate_content_type(response) }
      response.verify
    end

    def test_content_type_with_charset_suffix_currently_raises
      response = Minitest::Mock.new
      response.expect(:headers, { content_type: "image/svg+xml; charset=utf-8" })

      assert_raises(RuntimeError) { ::Jekyll::Kroki.validate_content_type(response) }
      response.verify
    end
  end

  class TestKrokiRendering < Minitest::Test
    include KrokiTestHelpers

    def setup
      @connection = Minitest::Mock.new
      # Reset the diagram cache before each test so that cached results from a previous
      # test do not affect the next one.
      ::Jekyll::Kroki.instance_variable_set(:@diagram_cache, Concurrent::Map.new)
    end

    def test_render_diagram_success
      diagram_text = "graph TD; A-->B;"
      response = svg_response

      @connection.expect(:get, response, ["mermaid/svg/#{encode(diagram_text)}"])

      result = ::Jekyll::Kroki.render_diagram(@connection, diagram_text, "mermaid")

      assert_equal "<?xml version=\"1.0\"?>\n<svg/>\n", result
      @connection.verify
    end

    def test_render_diagram_raises_on_connection_failure
      diagram_text = "graph TD; A-->B;"
      @connection.expect(:get, nil) { raise "Connection failed" }

      assert_raises(RuntimeError) do
        ::Jekyll::Kroki.render_diagram(@connection, diagram_text, "mermaid")
      end

      @connection.verify
    end

    def test_render_diagram_raises_on_incorrect_content_type
      diagram_text = "graph TD; A-->B;"
      # NOTE: body is stubbed here but will never be read because validate_content_type
      # raises before the body is accessed. The expectation is kept for completeness.
      response = Minitest::Mock.new
      response.expect(:headers, { content_type: "text/html" })

      @connection.expect(:get, response, ["mermaid/svg/#{encode(diagram_text)}"])

      assert_raises(RuntimeError) do
        ::Jekyll::Kroki.render_diagram(@connection, diagram_text, "mermaid")
      end

      @connection.verify
    end

    def test_render_diagram_is_cached_after_first_call
      diagram_text = "graph TD; A-->B;"
      @connection.expect(:get, svg_response, ["mermaid/svg/#{encode(diagram_text)}"])

      first_result  = ::Jekyll::Kroki.render_diagram(@connection, diagram_text, "mermaid")
      second_result = ::Jekyll::Kroki.render_diagram(@connection, diagram_text, "mermaid")

      assert_equal first_result, second_result
      # Verifying the mock ensures :get was called exactly once — a second call
      # would raise a MockExpectationError because no further :get is expected.
      @connection.verify
    end

    def test_failed_render_is_not_cached
      diagram_text = "graph TD; A-->B;"

      # First call raises.
      @connection.expect(:get, nil) { raise "transient error" }
      # Second call succeeds.
      @connection.expect(:get, svg_response, ["mermaid/svg/#{encode(diagram_text)}"])

      assert_raises(RuntimeError) do
        ::Jekyll::Kroki.render_diagram(@connection, diagram_text, "mermaid")
      end

      # Should succeed on retry without returning nil/stale cached value.
      result = ::Jekyll::Kroki.render_diagram(@connection, diagram_text, "mermaid")

      assert_includes result, "<svg"
      @connection.verify
    end

    def test_cache_is_keyed_per_language
      diagram_text = "graph TD; A-->B;"
      encoded = encode(diagram_text)
      @connection.expect(:get, svg_response("mermaid"),  ["mermaid/svg/#{encoded}"])
      @connection.expect(:get, svg_response("graphviz"), ["graphviz/svg/#{encoded}"])

      mermaid_result  = ::Jekyll::Kroki.render_diagram(@connection, diagram_text, "mermaid")
      graphviz_result = ::Jekyll::Kroki.render_diagram(@connection, diagram_text, "graphviz")

      refute_equal mermaid_result, graphviz_result
      @connection.verify
    end

    def test_cache_is_keyed_per_diagram_text
      diagram_text_a = "graph TD; A-->B;"
      diagram_text_b = "graph TD; X-->Y;"
      @connection.expect(:get, svg_response("a"), ["mermaid/svg/#{encode(diagram_text_a)}"])
      @connection.expect(:get, svg_response("b"), ["mermaid/svg/#{encode(diagram_text_b)}"])

      result_a = ::Jekyll::Kroki.render_diagram(@connection, diagram_text_a, "mermaid")
      result_b = ::Jekyll::Kroki.render_diagram(@connection, diagram_text_b, "mermaid")

      refute_equal result_a, result_b
      @connection.verify
    end
  end

  class TestKrokiEmbed < Minitest::Test
    include KrokiTestHelpers

    def setup
      @connection = Minitest::Mock.new
      ::Jekyll::Kroki.instance_variable_set(:@diagram_cache, Concurrent::Map.new)
    end

    def test_embed_single_doc_returns_diagram_count
      doc = Minitest::Mock.new
      doc.expect(:output, "<div class='language-mermaid'>graph TD; A-->B;</div>")
      doc.expect(:output=, nil, [String])

      @connection.expect(:get, svg_response, ["mermaid/svg/#{encode("graph TD; A-->B;")}"])

      rendered_diag = ::Jekyll::Kroki.embed_single_doc(@connection, doc)

      assert_equal 1, rendered_diag
      @connection.verify
    end

    def test_embed_single_doc_returns_zero_when_no_diagrams
      doc = Minitest::Mock.new
      doc.expect(:output, "<p>No diagrams here.</p>")

      result = ::Jekyll::Kroki.embed_single_doc(@connection, doc)

      assert_equal 0, result
      doc.verify
    end

    def test_embed_single_doc_multiple_diagrams
      mermaid_text  = "graph TD; A-->B;"
      graphviz_text = "digraph G { A -> B }"
      html = "<div class='language-mermaid'>#{mermaid_text}</div>" \
             "<div class='language-graphviz'>#{graphviz_text}</div>"

      doc = Minitest::Mock.new
      doc.expect(:output, html)
      doc.expect(:output=, nil, [String])

      @connection.expect(:get, svg_response("m"), ["mermaid/svg/#{encode(mermaid_text)}"])
      @connection.expect(:get, svg_response("g"), ["graphviz/svg/#{encode(graphviz_text)}"])

      result = ::Jekyll::Kroki.embed_single_doc(@connection, doc)

      assert_equal 2, result
      @connection.verify
      doc.verify
    end

    def test_embed_site
      site = setup_mock_site
      connection = Minitest::Mock.new
      connection.expect(:get, svg_response, ["mermaid/svg/#{encode("graph TD; A-->B;")}"])

      ::Jekyll::Kroki.stub(:setup_connection, connection) do
        ::Jekyll::Kroki.embed_site(site)
      end

      site.verify
      connection.verify
    end

    def test_embed_docs_handles_errors_in_individual_docs
      site = Minitest::Mock.new
      site.expect(:pages, [])
      bad_doc  = create_mock_doc("fail", "bad_doc.md")
      good_doc = create_mock_doc("graph TD; A-->B;", "good_doc.md")
      site.expect(:documents, [bad_doc, good_doc])
      max_concurrent_docs = 8

      result = Jekyll::Kroki.stub(:embed_single_doc, lambda { |_conn, doc|
        doc.output.include?("fail") ? raise("bad!") : 1
      }) do
        Jekyll::Kroki.embed_docs_in_site(site, @connection, max_concurrent_docs)
      end

      # One doc failed (counts as 0), one succeeded (counts as 1).
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
      site.expect(:config, { "kroki" => { "url" => "https://kroki.io" } })
      site.expect(:pages, [])
      site.expect(:documents, [create_mock_doc("graph TD; A-->B;")])
      site
    end

    def setup_two_doc_site(diagram_text)
      site = Minitest::Mock.new
      site.expect(:config, { "kroki" => { "url" => "https://kroki.io" } })
      site.expect(:pages, [])
      site.expect(:documents, [
                    create_mock_doc(diagram_text, "doc1.md"),
                    create_mock_doc(diagram_text, "doc2.md")
                  ])

      connection = Minitest::Mock.new
      connection.expect(:get, svg_response, ["mermaid/svg/#{encode(diagram_text)}"])

      [site, connection]
    end
  end
end
