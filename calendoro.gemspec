# frozen_string_literal: true

require_relative "lib/calendoro/version"

Gem::Specification.new do |s|
  s.name = "calendoro"
  s.version = Calendoro::VERSION
  s.summary = "Ruby client for the Calendoro scheduling API"
  s.authors = ["Calendoro contributors"]
  s.license = "MIT"
  s.homepage = "https://github.com/Calendoro/calendoro-ruby"
  s.metadata = { "source_code_uri" => "https://github.com/Calendoro/calendoro-ruby/tree/main/sdks/ruby", "rubygems_mfa_required" => "true" }
  s.required_ruby_version = ">= 3.1"
  s.files = Dir["lib/**/*.rb", "sig/**/*.rbs", "README.md"]
  s.require_paths = ["lib"]
end
