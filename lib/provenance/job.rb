# frozen_string_literal: true

module Provenance
  # ActiveJob integration, included into ActiveJob::Base. Each performed job is a
  # +job+ action; the enqueuing action's id and actor travel in the job payload
  # under the "provenance" key.
  module Job
    extend ActiveSupport::Concern

    # Job payload key.
    KEY = "provenance"

    included do
      class_attribute :_provenance_skip, instance_accessor: false, default: false
      around_perform { |job, block| Provenance::Job.perform(job, &block) }
    end

    class_methods do
      # Excludes this job class from auditing.
      #
      # @return [void]
      def skip_provenance
        self._provenance_skip = true
      end
    end

    # @return [Hash, nil] the deserialized "provenance" payload
    attr_reader :provenance_parent

    # @api private
    def serialize
      data = super
      action = Provenance.current
      if action && Provenance.enabled?
        data[KEY] = {"action_id" => action.id, "actor" => action.actor&.to_h}
      end
      data
    end

    # @api private
    def deserialize(job_data)
      super
      @provenance_parent = job_data[KEY]
    end

    # Runs a job inside a +job+ action.
    #
    # @param job [ActiveJob::Base]
    # @return [Object]
    def self.perform(job, &block)
      return Provenance.without(&block) if job.class._provenance_skip
      return block.call unless Provenance.enabled?

      parent = job.provenance_parent || {}
      actor = parent["actor"] && Actor.wrap(parent["actor"])
      Provenance.track(
        kind: :job, name: job.class.name, actor: actor, caused_by: parent["action_id"],
        context: Context.new(job: job)
      ) { block.call }
    end
  end
end
