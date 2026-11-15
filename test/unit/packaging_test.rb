require "test_helper"

class PackagingTest < ActiveSupport::TestCase
  test "gem ships runtime files only" do
    spec = Gem::Specification.load(File.expand_path("../../agentboard.gemspec", __dir__))
    files = spec.files
    assert_includes files, "exe/agentboard"
    assert_includes files, "lib/agentboard/providers/fake_agent_script.rb"
    assert_includes files, "app/assets/stylesheets/agentboard/application.css"
    assert files.any? { |f| f.start_with?("db/migrate/") }
    assert files.any? { |f| f.start_with?("lib/generators/agentboard/install/templates/") }
    refute files.any? { |f| f.start_with?("test/", ".github/") }, "tests and CI config are not packaged"
    assert_equal [ "agentboard" ], spec.executables
    refute spec.runtime_dependencies.map(&:name).include?("sqlite3"), "no database driver forced on hosts"
  end
end
