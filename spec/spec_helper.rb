require 'rspec'
require 'yaml'
require 'json'
require 'open3'
require 'bosh/template/test'

RELEASE_DIR = File.expand_path('..', __dir__)

module TemplateHelpers
  # Source a rendered bash data file and evaluate a bash snippet against it
  def bash(rendered, snippet)
    script = "set -eu\n#{rendered}\n#{snippet}\n"
    out, err, status = Open3.capture3('bash', '-c', script)
    raise "bash failed: #{err}" unless status.success?
    out
  end

  def b64decode_var(rendered, expr)
    bash(rendered, %(printf '%s' "#{expr}" | base64 -d))
  end
end

RSpec.configure do |c|
  c.include TemplateHelpers
end
