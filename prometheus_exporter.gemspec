# frozen_string_literal: true

lib = File.expand_path("../lib", __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "prometheus_exporter/version"

Gem::Specification.new do |spec|
  spec.name = "prometheus_exporter"
  spec.version = PrometheusExporter::VERSION
  spec.authors = ["Sam Saffron"]
  spec.email = ["sam.saffron@gmail.com"]

  spec.summary = "Prometheus Exporter"
  spec.description = "Prometheus metric collector and exporter for Ruby"
  spec.homepage = "https://github.com/discourse/prometheus_exporter"
  spec.license = "MIT"

  spec.required_ruby_version = ">= 3.2.0"

  spec.files = Dir['README.md', 'CHANGELOG', 'LICENSE.txt', 'lib/**/*.rb', 'exe/*']

  spec.bindir = "exe"
  spec.executables = ["prometheus_exporter"]

  spec.require_paths = ["lib"]

  spec.add_dependency "rack", ">= 3.2.0", "< 4"
  spec.add_dependency "rackup"

  spec.add_development_dependency "m"
  spec.add_development_dependency "mini_racer"
  spec.add_development_dependency "minitest"
  spec.add_development_dependency "minitest-mock"
  spec.add_development_dependency "minitest-stub-const"
  spec.add_development_dependency "debug"
  spec.add_development_dependency "oj"
  spec.add_development_dependency "rack-test"
  spec.add_development_dependency "rake"
  spec.add_development_dependency "redis"
  spec.add_development_dependency "syntax_tree"
  spec.add_development_dependency "syntax_tree-disable_ternary"
  spec.add_development_dependency "simplecov"
  spec.add_development_dependency "webrick"
  spec.add_development_dependency "puma"
  spec.add_development_dependency "falcon"
  spec.add_development_dependency "guard"
  spec.add_development_dependency "guard-minitest"
  spec.add_development_dependency "rubocop"
  spec.add_development_dependency "rubocop-discourse"
end
