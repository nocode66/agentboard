ENV["RAILS_ENV"] = "test"

require_relative "../test/dummy/config/environment"
require "rails/test_help"
require "agentboard/testing"

Agentboard::Testing.prepare_database!

class ActiveSupport::TestCase
  include Agentboard::Testing::Helpers
end
