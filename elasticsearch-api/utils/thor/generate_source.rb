# Licensed to Elasticsearch B.V under one or more agreements.
# Elasticsearch B.V licenses this file to you under the Apache 2.0 License.
# See the LICENSE file in the project root for more information

# encoding: UTF-8

require 'thor'
require 'pathname'
require 'active_support/core_ext/hash/deep_merge'
require 'active_support/inflector'
require 'multi_json'
require 'coderay'
require 'pry'
require_relative 'generator/files_helper'
require_relative 'generator/endpoint_specifics'

module Elasticsearch
  module API
    # A command line application based on [Thor](https://github.com/wycats/thor),
    # which will read the JSON API spec file(s), and generate
    # the Ruby source code (one file per API endpoint) with correct
    # module namespace, method names, and RDoc documentation,
    # as well as test files for each endpoint.
    #
    # Specific exceptions and code snippets that need to be included are written
    # in EndpointSpecifics (generator/endpoint_specifics) and the module is included
    # here.
    #
    class SourceGenerator < Thor
      namespace 'api:code'
      include Thor::Actions
      include EndpointSpecifics

      __root = Pathname(File.expand_path('../../..', __FILE__))

      desc 'generate', 'Generate source code and tests from the REST API JSON specification'
      method_option :verbose, type: :boolean, default: false, desc: 'Output more information'
      method_option :tests,   type: :boolean, default: false, desc: 'Generate test files'
      method_option :xpack,   type: :boolean, default: false, desc: 'Generate X-Pack'

      def generate
        self.class.source_root File.expand_path(__dir__)
        @xpack = options[:xpack]

        @input = FilesHelper.input_dir(@xpack)
        @output = FilesHelper.output_dir(@xpack)

        FilesHelper.files(@xpack).each do |filepath|
          @path = Pathname(@input.join(filepath))
          @json = MultiJson.load(File.read(@path))
          @spec = @json.values.first
          say_status 'json', @path, :yellow

          @spec['url'] ||= {}

          @endpoint_name    = @json.keys.first
          @full_namespace   = __full_namespace
          @namespace_depth  = @full_namespace.size > 0 ? @full_namespace.size - 1 : 0
          @module_namespace = @full_namespace[0, @namespace_depth]
          @method_name      = @full_namespace.last
          @parts            = __endpoint_parts
          @params           = @spec['params'] || {}
          @specific_params  = specific_params(@module_namespace.first) # See EndpointSpecifics
          @http_method      = __http_method
          @paths            = @spec['url']['paths'].map { |b| b['path'] }
          # Using Ruby's safe operator on array:
          @deprecation_note = @spec['url']['paths'].last&.[]('deprecated')
          @http_path        = __http_path
          @required_parts   = __required_parts

          @module_namespace.shift if @module_namespace.first == 'xpack'
          @path_to_file = @output.join(@module_namespace.join('/')).join("#{@method_name}.rb")
          dir = @output.join(@module_namespace.join('/'))
          empty_directory(dir, verbose: false)

          # Write the file with the ERB template:
          template('templates/method.erb', @path_to_file, force: true)

          print_source_code(@path_to_file) if options[:verbose]

          generate_tests if options[:tests]

          puts
        end

        run_rubocop

        # -- Tree output
        print_tree if options[:verbose]
      end

      private

      def __full_namespace
        names = @endpoint_name.split('.')
        if @xpack
          names = (names.first == 'xpack' ? names : ['xpack', names].flatten)
          # Return an array with 'ml' renamed to 'machine_learning' and 'ilm' to
          # 'index_lifecycle_management'
          names.map do |name|
            name
              .gsub(/^ml$/, 'machine_learning')
              .gsub(/^ilm$/, 'index_lifecycle_management')
          end
        else
          names
        end
      end

      # Create the hierarchy of directories based on API namespaces
      #
      def __create_directories(key, value)
        return if value['documentation']

        empty_directory @output.join(key)
        create_directory_hierarchy * value.to_a.first
      end

      # Extract parts from each path
      #
      def __endpoint_parts
        parts = @spec['url']['paths'].select do |a|
          a.keys.include?('parts')
        end.map do |path|
          path&.[]('parts')
        end
        (parts.inject(&:merge) || [])
      end

      def __http_method
        case @endpoint_name
        when 'index'
          '_id ? Elasticsearch::API::HTTP_PUT : Elasticsearch::API::HTTP_POST'
        when 'count'
          <<~SRC
            if arguments[:body]
              Elasticsearch::API::HTTP_POST
            else
              Elasticsearch::API::HTTP_GET
            end
          SRC
        else
          "Elasticsearch::API::HTTP_#{@spec['url']['paths'].map { |a| a['methods'] }.flatten.first}"
        end
      end

      def __http_path
        return "\"#{__parse_path(@paths.first)}\"" if @paths.size == 1
        return termvectors_path if @method_name == 'termvectors'

        result = ''
        anchor_string = ''
        @paths.sort { |a, b| b.length <=> a.length }.each_with_index do |path, i|
          var_string = __extract_path_variables(path).map { |var| "_#{var}" }.join(' && ')
          next if anchor_string == var_string

          anchor_string = var_string
          result += if i.zero?
                      "if #{var_string}\n"
                    elsif (i == @paths.size - 1) || var_string.empty?
                      "else\n"
                    else
                      "elsif #{var_string}\n"
                    end
          result += "\"#{__parse_path(path)}\"\n"
        end
        result += 'end'
        result
      end

      def __parse_path(path)
        path.gsub(/^\//, '')
            .gsub(/\/$/, '')
            .gsub('{', "\#{#{__utils}.__listify(_")
            .gsub('}', ')}')
      end

      def __path_variables
        @paths.map do |path|
          __extract_path_variables(path)
        end
      end

      # extract values that are in the {var} format:
      def __extract_path_variables(path)
        path.scan(/{(\w+)}/).flatten
      end

      # Find parts that are definitely required and should raise an error if
      # they're not present
      #
      def __required_parts
        required = []
        return required if @endpoint_name == 'tasks.get'

        required << 'body' if (@spec['body'] && @spec['body']['required'])
        # Get required variables from paths:
        req_variables = __path_variables.inject(:&) # find intersection
        required << req_variables unless req_variables.empty?
        required.flatten
      end

      def docs_helper(name, info)
        info['type'] = 'String' if info['type'] == 'enum' # Rename 'enums' to 'strings'
        tipo = info['type'] ? info['type'].capitalize : 'String'
        description = info['description'] ? info['description'].strip : '[TODO]'
        options = info['options'] ? "\n    #   (options: #{info['options'].join(', '.strip)})\n" : ''
        required = info['required'] ? ' (*Required*)' : ''
        deprecated = info['deprecated'] ? ' *Deprecated*' : ''
        "# @option arguments [#{tipo}] :#{name} #{description} #{required} #{deprecated} #{options}\n"
      end

      def generate_tests
        copy_file 'templates/test_helper.rb', @output.join('test').join('test_helper.rb')

        @test_directory = @output.join('test/api').join(@module_namespace.join('/'))
        @test_file      = @test_directory.join("#{@method_name}_test.rb")

        empty_directory @test_directory
        template 'templates/test.erb', @test_file

        print_source_code(@test_file) if options[:verbose]
      end

      def print_source_code(path_to_file)
        colorized_output = CodeRay.scan_file(path_to_file, :ruby).terminal
        lines            = colorized_output.split("\n")
        formatted        = lines.first + "\n" + lines[1, lines.size].map { |l| ' ' * 14 + l }.join("\n")

        say_status('ruby', formatted, :yellow)
      end

      def print_tree
        return unless `which tree > /dev/null 2>&1; echo $?`.to_i < 1

        lines = `tree #{@output}`.split("\n")
        say_status('tree', lines.first + "\n" + lines[1, lines.size].map { |l| ' ' * 14 + l }.join("\n"))
      end

      def __utils
        @xpack ? 'Elasticsearch::API::Utils' : 'Utils'
      end

      def run_rubocop
        system("rubocop --format autogenconf -x #{FilesHelper::output_dir(@xpack)}")
      end
    end
  end
end