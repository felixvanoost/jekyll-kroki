# frozen_string_literal: true

require "test_helper"

module Jekyll
  class TestKroki < Minitest::Test
    def test_that_it_has_a_version_number
      refute_nil ::Jekyll::Kroki::VERSION
    end

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
end
