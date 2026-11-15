require "test_helper"

# Guards the import map contract: the dashboard JS must import names that the vendored
# Turbo/Stimulus ESM builds actually export (a mismatch silently broke live updates once).
class JavascriptContractTest < ActiveSupport::TestCase
  def exports_of(path)
    src = File.read(path)
    src.scan(/export\s*\{([^}]*)\}/).flatten.flat_map { |list| list.split(",").map { |e| e.strip.split(/\s+as\s+/).last } }
  end

  test "dashboard imports exist in the shipped Turbo and Stimulus builds" do
    js = File.read(Agentboard::Engine.root.join("app/javascript/agentboard/application.js"))
    turbo_exports = exports_of(Agentboard::AssetsController.asset_paths.fetch("turbo.js"))
    stimulus_exports = exports_of(Agentboard::AssetsController.asset_paths.fetch("stimulus.js"))
    js.scan(/import\s*\{([^}]*)\}\s*from\s*"@hotwired\/turbo"/).flatten.flat_map { |l| l.split(",").map(&:strip) }.each do |name|
      assert_includes turbo_exports, name, "turbo.js does not export #{name}"
    end
    js.scan(/import\s*\{([^}]*)\}\s*from\s*"@hotwired\/stimulus"/).flatten.flat_map { |l| l.split(",").map(&:strip) }.each do |name|
      assert_includes stimulus_exports, name, "stimulus.js does not export #{name}"
    end
    refute_match(/import \* as Turbo/, js)
  end
end
