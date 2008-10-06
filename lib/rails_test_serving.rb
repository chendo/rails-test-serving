require 'test/unit'
require 'drb/unix'
require 'stringio'

module RailsTestServing
  SERVICE_URI = "drbunix:tmp/sockets/test_server.sock"
  
  def self.boot
    if ARGV.delete('--serve')
      Server.start
    else
      Client.run_tests
    end
  end
  
  module ConstantManagement
    extend self
    
    def legit?(const)
      !const.to_s.empty? && constantize_safely(const) == const
    end
    
    def constantize_safely(name)
      eval("#{name} if defined? #{name}", TOPLEVEL_BINDING)
    end
    
    def constantize(name)
      name.to_s.split('::').inject(Object) { |namespace, short| namespace.const_get(short) }
    end
    
    # ActiveSupport's Module#remove_class doesn't behave quite the way I would expect it to.
    def remove_constants(*names)
      names.each do |name|
        namespace, short = name.to_s =~ /^(.+)::(.+?)$/ ? [$1, $2] : ['Object', name]
        constantize(namespace).module_eval { remove_const(short) if const_defined?(short) }
      end
    end
    
    def subclasses_of(parent, options={})
      children = []
      ObjectSpace.each_object(Class) { |klass| children << klass if klass < parent && (!options[:legit] || legit?(klass)) }
      children
    end
  end
  
  module Client
    extend self
    
    def tests_on_exit=(yes)
      Test::Unit.run = !yes
    end
    
    def disable
      @disabled = true
      yield
    ensure
      @disabled = false
    end
    
    def run_tests
      return if @disabled
      Client.tests_on_exit = false
      server = DRbObject.new_with_uri(SERVICE_URI)
      begin
        puts server.run($0, ARGV)
        exit 0
      rescue DRb::DRbConnError
        Client.tests_on_exit = true
      end
    end
  end
  
  class Server
    include ConstantManagement
    
    TESTCASE_CLASS_NAMES =
      %w( Test::Unit::TestCase
          ActiveSupport::TestCase
          ActionView::TestCase
          ActionController::TestCase
          ActionController::IntegrationTest )
    
    def self.start
      DRb.start_service(SERVICE_URI, Server.new)
      DRb.thread.join
    end
    
    def initialize
      enable_dependency_tracking
      start_cleaner
    end
    
    def run(file, argv)
      check_cleaner_health
      sleep 0.01 until @cleaner.stop?
      
      with_default_testrunner_io(StringIO.new) do
        with_fixed_objectspace_collector do
          Client.disable { load(file) }
          Test::Unit::AutoRunner.run(false, nil, argv)
          @cleaner.wakeup
        end
      end.string
    end
    
  private
  
    def enable_dependency_tracking
      require 'initializer'
      
      Rails::Configuration.class_eval do
        def cache_classes
          false
        end
      end
    end
    
    def start_cleaner
      @cleaner = Thread.new do
        Thread.abort_on_exception = true
        loop do
          Thread.stop
          remove_tests
          reload_app
        end
      end
    end
    
    def check_cleaner_health
      unless @cleaner.alive?
        STDERR.puts "error: cleaning thread died, restarting"
        start_cleaner
      end
    end
    
    def remove_tests
      TESTCASE_CLASS_NAMES.each do |name|
        next unless klass = constantize_safely(name)
        remove_constants(*subclasses_of(klass).map { |c| c.to_s }.grep(/Test$/) - TESTCASE_CLASS_NAMES)
      end
    end
    
    def reload_app
      dispatcher = ActionController::Dispatcher.new($stdout)
      dispatcher.cleanup_application
      dispatcher.reload_application
    end
    
    def with_default_testrunner_io(io)
      require 'test/unit/ui/console/testrunner'
      
      Test::Unit::UI::Console::TestRunner.class_eval do
        alias_method :old_initialize, :initialize
        def initialize(suite, output_level, io=Thread.current["test_runner_io"])
          old_initialize(suite, output_level, io)
        end
      end
      Thread.current["test_runner_io"] = io
      
      begin
        yield
        return io
      ensure
        Thread.current["test_runner_io"] = nil
        Test::Unit::UI::Console::TestRunner.class_eval do
          alias_method :initialize, :old_initialize
          remove_method :old_initialize
        end
      end
    end
    
    def with_fixed_objectspace_collector
      require 'test/unit/collector/objectspace'
      
      Test::Unit::Collector::ObjectSpace.class_eval do
        alias_method :old_collect, :collect
        def collect(name)
          tests = []
          ConstantManagement.subclasses_of(Test::Unit::TestCase, :legit => true).each { |klass| add_suite(tests, klass.suite) }
          suite = Test::Unit::TestSuite.new(name)
          sort(tests).each { |t| suite << t }
          suite
        end
      end
      
      begin
        return yield
      ensure
        Test::Unit::Collector::ObjectSpace.class_eval do
          alias_method :collect, :old_collect
          remove_method :old_collect
        end
      end
    end
  end
end unless defined? RailsTestServing
