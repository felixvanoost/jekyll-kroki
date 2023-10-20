# jekyll-kroki
A Jekyll plugin to convert diagram descriptions into images using Kroki

## Installation

Add the `jekyll-kroki` Gem to the `:jekyll_plugins` group of your site's Gemfile:

```ruby
group :jekyll_plugins do
  gem "jekyll-kroki"
end
```

## Usage

[Kroki](https://github.com/yuzutech/kroki) supports over 20 popular diagram languages spanning several dozen diagram types. The [examples](https://kroki.io/examples.html) page provides a taste of what's possible.

In Markdown, simply write your diagram description inside a fenced code block with the language specified:

````
```plantuml
participant Jekyll
participant Kroki #MediumSpringGreen

Jekyll -> Kroki: Encoded diagram description
Kroki --> Jekyll: Rendered diagram in SVG format
```
````

When Jekyll builds your site, the `jekyll-kroki` plugin will encode the diagram, send it to the Kroki server for rendering, then replace the diagram description in the generated HTML with the rendered diagram in SVG format:

![sample-diagram](https://github.com/felixvanoost/jekyll-kroki/assets/10233016/244d2ec4-b09b-4a5f-8164-3851574c3dd2)

The site remains truly static as the SVG is directly embedded in the HTML files that Jekyll serves. Jekyll only depends on the Kroki server (which can also be run locally) during the build stage, and all of the client-side processing that is normally used to render diagrams into images is eliminated.

`jekyll-kroki` uses the same Markdown fenced code syntax as the [GitLab Kroki integration](https://docs.gitlab.com/ee/administration/integration/kroki.html), allowing diagram descriptions in Markdown files to be displayed seamlessly in both the GitLab UI and on GitLab Pages sites generated using Jekyll.

## Contributing

Bug reports and pull requests are welcome! For major changes, please open an issue first to discuss what you would like to change.
