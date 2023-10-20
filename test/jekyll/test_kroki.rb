# frozen_string_literal: true

require "test_helper"

module Jekyll
  class TestKroki < Minitest::Test
    def test_that_it_has_a_version_number
      refute_nil ::Jekyll::Kroki::VERSION
    end
  end
end
