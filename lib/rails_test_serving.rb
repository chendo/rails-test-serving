require 'fileutils'
require 'thread'
require 'test/unit'
require 'drb/unix'
require 'stringio'
require 'benchmark'

module RailsTestServing
  class InvalidArgumentPattern < ArgumentError
  end
  class ServerUnavailable < StandardError
  end
  
  #SERVICE_URI = "drbunix:tmp/sockets/test_server.sock"
  def self.service_uri
    @@service_uri ||= begin
      service_uri = if result = $:.inject(nil) do |found_path, path|
          next found_path if found_path
          next File.join(path, '..') if File.exists?(File.join(path, '../config/boot.rb'))
          next File.join(path, '..', '..') if File.exists?(File.join(path, '../../config/boot.rb'))
          next File.join(path, '..', '..', '..') if File.exists?(File.join(path, '../../../config/boot.rb'))
        end
        result = File.expand_path(result)
        $:.unshift(result)
        File.join(result, 'tmp/sockets/test_server.sock')
      else
        'tmp/sockets/test_server.sock'
      end
      FileUtils.mkdir_p(File.dirname(service_uri))
      service_uri
    end
    "drbunix:" + @@service_uri
  end
  
  SERVICE_URI = self.service_uri
  
  
  def self.boot(argv=ARGV)
    if argv.delete('--serve')
      Server.start
    elsif !argv.delete('--local')
      Client.run_tests
    end
  end
  
  module ConstantManagement
    extend self
    
    def legit?(const)
      !const.to_s.empty? && constantize(const) == const
    end
    
    def constantize(name)
      eval("#{name} if defined? #{name}", TOPLEVEL_BINDING)
    end
    
    def constantize!(name)
      name.to_s.split('::').inject(Object) { |namespace, short| namespace.const_get(short) }
    end
    
    # ActiveSupport's Module#remove_class doesn't behave quite the way I would expect it to.
    def remove_constants(*names)
      names.map do |name|
        namespace, short = name.to_s =~ /^(.+)::(.+?)$/ ? [$1, $2] : ['Object', name]
        constantize!(namespace).module_eval { remove_const(short) if const_defined?(short) }
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
    
    # Setting this variable to true inhibits #run_tests.
    @@disabled = false
    
    def disable
      @@disabled = true
      yield
    ensure
      @@disabled = false
    end
    
    def tests_on_exit
      !Test::Unit.run?
    end
    
    def tests_on_exit=(yes)
      Test::Unit.run = !yes
    end
    
    def run_tests
      return if @@disabled
      run_tests!
    end
  
  private
  
    def run_tests!
      handle_process_lifecycle do
        server = DRbObject.new_with_uri(SERVICE_URI)
        begin
          puts(server.run($0, ARGV))
        rescue DRb::DRbConnError
          raise ServerUnavailable
        end
      end
    end
    
    def handle_process_lifecycle
      Client.tests_on_exit = false
      begin
        yield
      rescue ServerUnavailable, InvalidArgumentPattern
        Client.tests_on_exit = true
      else
        # TODO exit with a status code reflecting the result of the tests
        exit 0
      end
    end
  end
  
  class Server
    GUARD = Mutex.new
    
    def self.start
      DRb.start_service(SERVICE_URI, Server.new)
      DRb.thread.join
    end
    
    def initialize
      ENV['RAILS_ENV'] = 'test'
      @options = (defined? TEST_SERVER_OPTIONS) ? TEST_SERVER_OPTIONS : {}
      @options[:reload] ||= []
      enable_dependency_tracking
      start_cleaner
      load_framework
      log "** Test server started (##{$$})\n"
    end
    
    def run(file, argv)
      GUARD.synchronize { perform_run(file, argv) }
    end
    
  private
  
    def log(message)
      $stdout.print(message)
      $stdout.flush
    end
    
    def shorten_path(path)
      shortenable, base = File.expand_path(path), File.expand_path(Dir.pwd)
      attempt = shortenable.sub(/^#{Regexp.escape base + File::SEPARATOR}/, '')
      attempt.length < path.length ? attempt : path
    end
    
    def enable_dependency_tracking
      require 'config/boot'
      
      Rails::Configuration.class_eval do
        unless method_defined? :cache_classes
          raise "#{self.class} out of sync with current Rails version"
        end
        
        def cache_classes
          false
        end
      end
    end
    
    def start_cleaner
      @cleaner = Cleaner.new(@options)
    end
    
    def load_framework
      Client.disable do
        $: << 'test'
        require 'test_helper'
      end
    end
    
    def perform_run(file, argv)
      sanitize_arguments! file, argv
      
      log ">> " + [shorten_path(file), *argv].join(' ')
      
      result = nil
      elapsed = Benchmark.realtime do
        result = capture_test_result(file, argv)
      end
      log " (%d ms)\n" % (elapsed * 1000)
      result
    end
    
    def sanitize_arguments!(file, argv)
      if file =~ /^-/
        # No file was specified for loading, only options. It's the case with
        # Autotest.
        raise InvalidArgumentPattern
      end
      
      # Filter out the junk that TextMate seems to inject into ARGV when running
      # focused tests.
      while a = find_index_by_pattern(argv, /^\[/) and z = find_index_by_pattern(argv[a..-1], /\]$/)
        argv[a..a+z] = []
      end
    end
    
    def capture_test_result(file, argv)
      result = []
      @cleaner.clean_up_around do
        result << capture_standard_stream('err') do
          result << capture_standard_stream('out') do
            result << capture_testrunner_result do
              fix_objectspace_collector do
                Client.disable { load(file) }
                Test::Unit::AutoRunner.run(false, nil, argv)
              end
            end
          end
        end
      end
      result.reverse.join
    end
    
    def capture_standard_stream(name)
      eval("old, $std#{name} = $std#{name}, StringIO.new")
      begin
        yield
        return eval("$std#{name}").string
      ensure
        eval("$std#{name} = old")
      end
    end
    
    def capture_testrunner_result
      set_default_testrunner_stream(io = StringIO.new) { yield }
      io.string
    end
    
    # The default output stream of TestRunner is STDOUT which cannot be captured
    # and, as a consequence, neither can TestRunner output when not instantiated
    # explicitely. The following method can change the default output stream
    # argument so that it can be set to a stream that can be captured instead.
    def set_default_testrunner_stream(io)
      require 'test/unit/ui/console/testrunner'
      
      Test::Unit::UI::Console::TestRunner.class_eval do
        alias_method :old_initialize, :initialize
        def initialize(suite, output_level, io=Thread.current["test_runner_io"])
          old_initialize(suite, output_level, io)
        end
      end
      Thread.current["test_runner_io"] = io
      
      begin
        return yield
      ensure
        Thread.current["test_runner_io"] = nil
        Test::Unit::UI::Console::TestRunner.class_eval do
          alias_method :initialize, :old_initialize
          remove_method :old_initialize
        end
      end
    end
    
    # The stock ObjectSpace collector collects every single class that inherits
    # from Test::Unit, including those which have just been unassigned from
    # their constant and not yet garbage collected. This method fixes that
    # behaviour by filtering out these soon-to-be-garbage-collected classes.
    def fix_objectspace_collector
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
    
  private
  
    def find_index_by_pattern(enumerable, pattern)
      enumerable.each_with_index do |element, index|
        return index if pattern === element
      end
      nil
    end
  end
  
  class Cleaner
    include ConstantManagement
    
    BREATH = 0.01
    TESTCASE_CLASS_NAMES =  %w( Test::Unit::TestCase
                                ActiveSupport::TestCase
                                ActionView::TestCase
                                ActionController::TestCase
                                ActionController::IntegrationTest
                                ActionMailer::TestCase )
    
    def initialize(options = {})
      @options = options
      start_worker
    end
    
    def clean_up_around
      check_worker_health
      sleep BREATH while @working
      begin
        reload_app
        yield
      ensure
        @working = true
        sleep BREATH until @worker.stop?
        @worker.wakeup
      end
    end
    
  private
    
    def start_worker
      @worker = Thread.new do
        Thread.abort_on_exception = true
        loop do
          Thread.stop
          begin
            clean_up_app
            remove_tests
          ensure
            @working = false
          end
        end
      end
      @working = false
    end
    
    def check_worker_health
      unless @worker.alive?
        $stderr.puts "cleaning thread died, restarting"
        start_worker
      end
    end
    
    def clean_up_app
      ActionController::Dispatcher.new(StringIO.new).cleanup_application
      if @options[:reload].length > 0
        matched_files = []
        
        # Force a reload by removing matched files from $"
        $".delete_if do |path|
          if @options[:reload].any? { |regex| File.expand_path(path).gsub(RAILS_ROOT, '') =~ Regexp.new(regex) }
            matched_files << path
            true
          else
            false
          end
        end
        matched_files.each do |file|
          # Expanding the path to prevent files from requiring twice
          require File.expand_path(file)
        end
      end
    end
    
    def remove_tests
      TESTCASE_CLASS_NAMES.each do |name|
        next unless klass = constantize(name)
        remove_constants(*subclasses_of(klass).map { |c| c.to_s }.grep(/Test$/) - TESTCASE_CLASS_NAMES)
      end
    end
    
    def reload_app
      ActionController::Dispatcher.new(StringIO.new).reload_application
    end
  end
end unless defined? RailsTestServing
