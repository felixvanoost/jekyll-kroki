![Main Workflow](https://github.com/felixvanoost/jekyll-kroki/actions/workflows/main.yml/badge.svg) 
[![Gem Version](https://badge.fury.io/rb/jekyll-kroki.svg)](https://badge.fury.io/rb/jekyll-kroki)

# jekyll-kroki
A [Jekyll](https://jekyllrb.com/) plugin to convert diagram descriptions into images using [Kroki](https://kroki.io/).

## Installation
Add the `jekyll-kroki` Gem to the `:jekyll_plugins` group of your site's Gemfile:

```ruby
group :jekyll_plugins do
  gem "jekyll-kroki"
end
```

## Usage
Kroki supports over 25 popular diagram scripting languages, including Blockdiag, D2, GraphViz, Mermaid, and PlantUML. The [examples](https://kroki.io/examples.html) page and complete list of [supported diagram languages](https://kroki.io/#support) provide a taste of what's possible.

In Markdown, simply write your diagram descriptions inside a fenced code block with the language specified:

````
```plantuml
participant Jekyll
participant Kroki #MediumSpringGreen

Jekyll -> Kroki: Encoded diagram description
Kroki --> Jekyll: Rendered diagram in SVG format
```
````

When Jekyll builds your site, the `jekyll-kroki` plugin will encode the diagrams, send them to the Kroki server for rendering, then replace the diagram descriptions in the generated HTML with the rendered images in SVG format:

![sample-diagram](https://github.com/felixvanoost/jekyll-kroki/assets/10233016/244d2ec4-b09b-4a5f-8164-3851574c3dd2)

The site remains fully static as the images are directly embedded in the HTML files served by Jekyll. Jekyll only depends on the Kroki server - which can also be run locally - during the build stage, and all of the client-side processing that is normally used to render diagrams into images is eliminated.

### Advantages

#### Consistent syntax
Instead of using Liquid tags, `jekyll-kroki` leverages the same Markdown fenced code block syntax used by both [GitLab](https://docs.gitlab.com/ee/user/markdown.html#diagrams-and-flowcharts) and [GitHub](https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/creating-diagrams) to display diagrams. Besides being more consistent, this means that diagram descriptions in Markdown files can be displayed consistently as images across the GitLab/GitHub UI and on GitLab/GitHub Pages sites generated using Jekyll. GitLab currently supports Mermaid and PlantUML, while GitHub only supports Mermaid.

#### Seamless GitLab integration
Self-managed GitLab instances can additionally enable the [Kroki integration](https://docs.gitlab.com/ee/administration/integration/kroki.html), which adds support for all the same diagram scripting languages used by `jekyll-kroki`. Furthermore, by pointing both GitLab and `jekyll-kroki` to the same Kroki instance, you can guarantee that diagrams are generated using identical versions of the diagram libraries.

#### Speed
The server-side nature of Kroki means that you don't have to deal with installing or updating any diagram library dependencies on your machine. Jekyll sites that are generated in CI/CD pipelines will thus build faster.

#### Flexibility
Kroki is available either as a free service or self-hosted using Docker. Organisations that frequently build large Jekyll sites with many diagrams or want maximum control over their data have the option of running their own Kroki instance to provide consistency and use compute resources efficiently.

### Configuration
You can specify the following parameters in the Jekyll `_config.yml` file:

| Parameter | Default value | Description |
| --------- | ------------- | ----------- |
| `url` | `https://kroki.io` | The URL of the Kroki instance to use |
| `http_retries` | `3` | The number of HTTP retries |
| `http_timeout` | `15` | The HTTP timeout value in seconds |
| `max_concurrent_docs` | `8` | The maximum number of Jekyll documents to render concurrently |

For example:

```yaml
kroki:
  url: "https://my-kroki.server"
  http_retries: 3
  http_timeout: 15
  max_concurrent_docs: 8
```

### Security
Embedding diagrams as SVGs directly within HTML files can be dangerous. You should only use a Kroki instance that you trust (or run your own!). For additional security, you can configure a [Content Security Policy (CSP)](https://developer.mozilla.org/en-US/docs/Web/HTTP/CSP) using custom Webrick headers in the Jekyll `_config.yml` file:

```yaml
webrick:
  headers:
    Content-Security-Policy: "Add a policy here"
```

## Contributing
Bug reports and pull requests are welcome! For major changes, please open an issue first to discuss what you would like to change.
