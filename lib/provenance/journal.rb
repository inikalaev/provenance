# frozen_string_literal: true

module Provenance
  # Accumulates model and bulk changes for the current request, grouped by
  # transaction key so they can be discarded on rollback and flushed together
  # once every transaction has completed.
  class Journal
    attr_reader :changes

    def initialize
      @changes = []
      @active_transactions = Set.new
    end

    def register_transaction(transaction_id)
      return if transaction_id.nil?

      @active_transactions.add(transaction_id)
    end

    def complete_transaction(transaction_id)
      return if transaction_id.nil?

      @active_transactions.delete(transaction_id)
    end

    def add_change(model, action, data)
      change_data = {
        model: model.class.name,
        model_id: model.id,
        action: action.to_s,
        changes: filter_sensitive_data(data, model.class),
        timestamp: Time.current.utc.iso8601(3)
      }

      change_data[:transaction_id] = data[:transaction_id] if data.is_a?(Hash) && data[:transaction_id]

      @changes << change_data
    end

    def add_bulk_change(model_class, action, ids, updates, truncated: false, transaction_id: nil)
      change_data = {
        model: model_class.name,
        model_ids: ids,
        action: action.to_s,
        count: ids.size,
        changes: updates.nil? ? {} : filter_sensitive_data(updates, model_class),
        timestamp: Time.current.utc.iso8601(3)
      }
      change_data[:truncated] = true if truncated
      change_data[:transaction_id] = transaction_id if transaction_id

      @changes << change_data
    end

    def remove_changes_for_transaction(transaction_id)
      return if transaction_id.nil?

      @changes.reject! { |change| change[:transaction_id] == transaction_id }
      @active_transactions.delete(transaction_id)
    end

    def all_transactions_completed?
      @active_transactions.empty?
    end

    def to_h
      {
        count: @changes.size,
        changes: @changes
      }
    end

    def clear!
      @changes.clear
      @active_transactions.clear
    end

    def empty?
      @changes.empty?
    end

    def present?
      @changes.any?
    end

    private

    def filter_sensitive_data(data, model_class = nil)
      sensitive_attrs = model_sensitive_attributes(model_class)
      return data if sensitive_attrs.empty?

      case data
      when Hash
        filtered_data = {}
        data.each do |key, value|
          filtered_data[key] = if key == "transaction_id"
                                 value
                               elsif sensitive_attrs.include?(key.to_s)
                                 "[FILTERED]"
                               else
                                 filter_sensitive_data(value, model_class)
                               end
        end
        filtered_data
      when Array
        data.map { |item| filter_sensitive_data(item, model_class) }
      else
        data
      end
    end

    def model_sensitive_attributes(model_class)
      attributes = model_class&.attribute_names
      if model_class.respond_to?(:sensitive_attributes_list)
        attrs = model_class.sensitive_attributes_list
        attributes = attrs.map(&:to_s)
      end

      (Provenance.config.sensitive_attributes + attributes).map(&:to_s)
    end
  end
end
