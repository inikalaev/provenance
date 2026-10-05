# frozen_string_literal: true

require "provenance"
require "rspec/expectations"

module Provenance
  module Testing
    # Block matcher for emitted events.
    #
    # @example
    #   expect { patch invoice_path(invoice), params: {status: "sent"} }
    #     .to emit_provenance_event(action: "invoices#update", outcome: "success")
    #     .with_change(entity: "Invoice", operation: "update", diff: including(status: ["draft", "sent"]))
    class EmitEventMatcher
      include RSpec::Matchers::Composable

      # Expected attribute name -> path in the native event.
      PATHS = {
        action: %w[action name], kind: %w[action kind], caused_by: %w[action caused_by],
        outcome: %w[outcome result], error: %w[outcome error], actor: %w[actor], actor_id: %w[actor id],
        request: %w[request], status: %w[request status], metadata: %w[metadata], app: %w[app]
      }.freeze

      # @param expected [Hash] any of the keys in {PATHS}
      def initialize(expected)
        unknown = expected.keys - PATHS.keys
        raise ArgumentError, "unknown keys #{unknown.inspect}" if unknown.any?

        @expected = expected
        @changes = []
        @count = nil
      end

      # Requires a change matching the given attributes in the same event.
      #
      # @param expected [Hash] entity, entity_id, operation, diff, association, count, ids
      # @return [self]
      def with_change(**expected)
        @changes << expected
        self
      end

      # Requires exactly +n+ matching events.
      #
      # @param n [Integer]
      # @return [self]
      def exactly(n)
        @count = n
        self
      end

      # Alias for +exactly(1)+.
      #
      # @return [self]
      def once
        exactly(1)
      end

      # @return [Boolean]
      def supports_block_expectations?
        true
      end

      # @return [Boolean]
      def supports_value_expectations?
        false
      end

      # @param block [Proc]
      # @return [Boolean]
      def matches?(block)
        @events = Testing.capture(&block)
        @matching = @events.select { |event| event_matches?(event) }
        @count ? @matching.size == @count : @matching.any?
      end

      # @param block [Proc]
      # @return [Boolean]
      def does_not_match?(block)
        raise ArgumentError, "exactly/once is not supported with not_to" if @count

        @events = Testing.capture(&block)
        @matching = @events.select { |event| event_matches?(event) }
        @matching.empty?
      end

      # @return [String]
      def description
        "emit provenance event #{description_of(@expected)}" +
          @changes.map { |c| " with change #{description_of(c)}" }.join
      end

      # @return [String]
      def failure_message
        "expected block to #{description}#{" #{@count} time(s)" if @count}, " \
          "but #{@matching.size} of #{@events.size} emitted event(s) matched:\n#{dump}"
      end

      # @return [String]
      def failure_message_when_negated
        "expected block not to #{description}, but it emitted:\n#{dump(@matching)}"
      end

      private

      def event_matches?(event)
        @expected.all? { |key, value| values_match?(value, indifferent(event.dig(*PATHS.fetch(key)))) } &&
          @changes.all? { |expected| event["changes"].any? { |change| change_matches?(expected, change) } }
      end

      def change_matches?(expected, change)
        expected.all? { |key, value| values_match?(value, indifferent(change[key.to_s])) }
      end

      def indifferent(value)
        case value
        when Hash then value.to_h { |k, v| [k, indifferent(v)] }.with_indifferent_access
        when Array then value.map { |v| indifferent(v) }
        else value
        end
      end

      def dump(events = @events)
        events.map { |event| "  #{JSON.generate(event)}" }.join("\n")
      end
    end

    # RSpec helpers, included into every example group.
    module Matchers
      # @param expected [Hash] see {EmitEventMatcher::PATHS}
      # @return [EmitEventMatcher]
      def emit_provenance_event(**expected)
        EmitEventMatcher.new(expected)
      end
    end
  end
end

RSpec.configure { |config| config.include Provenance::Testing::Matchers } if defined?(RSpec.configure)
