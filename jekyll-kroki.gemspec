# frozen_string_literal: true

Gem::Specification.new do |s|
  s.name        = 'jekyll-kroki'
  s.version     = '0.0.0'
  s.summary     = 'A Jekyll plugin for the Kroki diagram engine'
  s.description = 'Renders diagrams written in any Kroki-supported language and embeds them as SVGs.'
  s.authors     = ['Felix van Oost']
  s.files       = ['lib/jekyll-kroki.rb']
  s.homepage    = 'https://github.com/FelixVanOost/jekyll-kroki'
  s.license     = 'MIT'

  s.required_ruby_version = '>= 3.0'

  s.add_runtime_dependency 'jekyll', ['~> 4']
  s.add_runtime_dependency 'nokogiri', ['~> 1.15']

  s.add_development_dependency 'rubocop', ['~> 1.57']
end
