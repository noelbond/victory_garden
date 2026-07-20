ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "factory_bot_rails"

module ActiveSupport
  class TestCase
    parallelize(workers: :number_of_processors)
    fixtures :all
    include FactoryBot::Syntax::Methods

    # Temporarily replaces klass's singleton method `method_name` with `callable`
    # for the duration of the block, then restores the original implementation.
    def stub_singleton_method(klass, method_name, callable)
      original = klass.method(method_name)
      klass.define_singleton_method(method_name, &callable)
      yield
    ensure
      klass.define_singleton_method(method_name, &original)
    end
  end
end
