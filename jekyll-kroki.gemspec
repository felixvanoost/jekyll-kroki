# frozen_string_literal: true

require_relative "lib/jekyll/kroki/version"

Gem::Specification.new do |spec|
  spec.name = "jekyll-kroki"
  spec.version = Jekyll::Kroki::VERSION
  spec.authors = ["Felix van Oost"]

  spec.summary = "A Jekyll plugin for the Kroki diagram engine"
  spec.description = "Replaces diagram descriptions written in any Kroki-supported language in HTML files with their
                      visual representation in SVG format"
  spec.homepage = "https://github.com/felixvanoost/jekyll-kroki"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 2.6.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage

  # Load the files that are versioned in Git into the RubyGem.
  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (File.expand_path(f) == __FILE__) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git appveyor Gemfile])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_runtime_dependency "jekyll", ["~> 4"]
  spec.add_runtime_dependency "nokogiri", ["~> 1.15"]

  spec.add_development_dependency "minitest", ["~> 5.0"]
  spec.add_development_dependency "rake", ["~> 13.0"]
  spec.add_development_dependency "rubocop", ["~> 1.21"]
end
