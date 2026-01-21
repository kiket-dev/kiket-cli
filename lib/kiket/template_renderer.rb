# frozen_string_literal: true

require "erb"

module Kiket
  # Renders ERB templates from the templates directory
  class TemplateRenderer
    TEMPLATES_DIR = File.expand_path("templates", __dir__)

    def initialize(base_path = TEMPLATES_DIR)
      @base_path = base_path
    end

    # Render a template with the given variables
    # @param template_path [String] Path relative to templates dir (e.g., "extensions/java/Handler.java.erb")
    # @param variables [Hash] Variables to make available in the template
    # @return [String] Rendered content
    def render(template_path, variables = {})
      full_path = File.join(@base_path, template_path)

      raise ArgumentError, "Template not found: #{full_path}" unless File.exist?(full_path)

      template_content = File.read(full_path)
      context = TemplateContext.new(variables)
      ERB.new(template_content, trim_mode: "-").result(context.get_binding)
    end

    # Copy a static template file (non-ERB) to destination
    # @param template_path [String] Path relative to templates dir
    # @param dest_path [String] Destination file path
    def copy(template_path, dest_path)
      full_path = File.join(@base_path, template_path)

      raise ArgumentError, "Template not found: #{full_path}" unless File.exist?(full_path)

      FileUtils.cp(full_path, dest_path)
    end

    # Render and write a template to a file
    # @param template_path [String] Path relative to templates dir
    # @param dest_path [String] Destination file path
    # @param variables [Hash] Variables for ERB rendering
    def render_to_file(template_path, dest_path, variables = {})
      content = render(template_path, variables)
      FileUtils.mkdir_p(File.dirname(dest_path))
      File.write(dest_path, content)
    end

    # Copy a static file to destination
    # @param template_path [String] Path relative to templates dir
    # @param dest_path [String] Destination file path
    def copy_to_file(template_path, dest_path)
      FileUtils.mkdir_p(File.dirname(dest_path))
      copy(template_path, dest_path)
    end

    # Template context for ERB evaluation
    class TemplateContext
      def initialize(variables)
        variables.each do |key, value|
          instance_variable_set("@#{key}", value)
          define_singleton_method(key) { instance_variable_get("@#{key}") }
        end
      end

      def get_binding
        binding
      end
    end
  end
end
