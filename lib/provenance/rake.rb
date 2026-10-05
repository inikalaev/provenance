# frozen_string_literal: true

module Provenance
  # Opt-in rake integration: every executed task becomes a +task+ action.
  #
  # @example Rakefile
  #   Provenance::Rake.install!
  module Rake
    # Prepended into Rake::Task.
    module TaskExtension
      # @api private
      def execute(args = nil)
        return super unless Provenance.enabled?

        Provenance.track(kind: :task, name: name) { super }
      end
    end

    # Wraps rake task execution. Idempotent.
    #
    # @return [void]
    def self.install!
      require "rake"
      ::Rake::Task.prepend(TaskExtension) unless ::Rake::Task.ancestors.include?(TaskExtension)
    end
  end
end
