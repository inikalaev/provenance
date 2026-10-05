# frozen_string_literal: true

module Provenance
  # Opt-in model tracking: +has_provenance+ and the hooks it installs.
  module Model
    # Bulk operations on relations of tracked models.
    module BulkRelation
      # @see ActiveRecord::Relation#update_all
      def update_all(updates)
        Provenance::Recorder.bulk(self, :bulk_update, updates: updates) { super }
      end

      # @see ActiveRecord::Relation#delete_all
      def delete_all
        Provenance::Recorder.bulk(self, :bulk_delete) { super }
      end

      # @see ActiveRecord::Relation#insert_all
      def insert_all(attributes, **options)
        Provenance::Recorder.bulk_insert(self, attributes) { super }
      end

      # @see ActiveRecord::Relation#insert_all!
      def insert_all!(attributes, **options)
        Provenance::Recorder.bulk_insert(self, attributes) { super }
      end

      # @see ActiveRecord::Relation#upsert_all
      def upsert_all(attributes, **options)
        Provenance::Recorder.bulk_insert(self, attributes) { super }
      end
    end

    # Bulk update through an association collection proxy.
    module BulkCollectionProxy
      # @see ActiveRecord::Relation#update_all
      def update_all(updates)
        Provenance::Recorder.bulk(self, :bulk_update, updates: updates) { super }
      end
    end

    # Keeps bulk tracking on STI subclasses defined after +has_provenance+.
    module Inheritance
      # @api private
      def inherited(subclass)
        super
        Provenance::Model.install_bulk(subclass)
      end
    end

    # Class macros added to ActiveRecord::Base.
    module ClassMethods
      # Opts the model in to change tracking.
      #
      # @param only [Array<Symbol>] track only these attributes
      # @param except [Array<Symbol>] track all attributes but these
      # @param redact [Array<Symbol>] record these attributes as "[REDACTED]"
      # @param associations [Array<Symbol>] collection associations producing link/unlink changes
      # @param ignore_if [Proc, nil] +->(record) { ... }+; truthy skips the record
      # @return [void]
      def has_provenance(only: nil, except: nil, redact: [], associations: [], ignore_if: nil)
        raise ArgumentError, "use either only: or except:, not both" if only && except

        options = Registry::Options.new(
          only: Array(only).map(&:to_s), except: Array(except).map(&:to_s),
          redact: Array(redact).map(&:to_s), associations: Array(associations).map(&:to_sym),
          ignore_if: ignore_if
        )
        Provenance.registry.register(self, options)
        Provenance::Model.install(self, options)
      end
    end

    module_function

    # @api private
    def install(model, options)
      unless model.instance_variable_get(:@provenance_installed)
        model.instance_variable_set(:@provenance_installed, true)
        model.after_create { Provenance::Recorder.record(self, :create) }
        model.after_update { Provenance::Recorder.record(self, :update) }
        model.after_destroy { Provenance::Recorder.record(self, :destroy) }
        model.singleton_class.prepend(Inheritance)
        ([model] + model.descendants).each { |klass| install_bulk(klass) }
      end
      installed = model.instance_variable_get(:@provenance_associations) || []
      (options.associations - installed).each { |name| install_association(model, name) }
      model.instance_variable_set(:@provenance_associations, installed | options.associations)
    end

    # @api private
    def install_bulk(model)
      prepend_once(model.relation_delegate_class(ActiveRecord::Relation), BulkRelation)
      prepend_once(model.relation_delegate_class(ActiveRecord::AssociationRelation), BulkRelation)
      prepend_once(model.relation_delegate_class(ActiveRecord::Associations::CollectionProxy), BulkCollectionProxy)
    end

    # @api private
    def prepend_once(klass, mod)
      klass.prepend(mod) unless klass.ancestors.include?(mod)
    end

    # Appends link/unlink recorders to the association's after_add/after_remove
    # callback lists.
    #
    # @api private
    def install_association(model, name)
      reflection = model.reflect_on_association(name)
      unless reflection&.collection?
        raise ArgumentError, "#{model.name} has no collection association #{name.inspect}"
      end

      {after_add: :link, after_remove: :unlink}.each do |callback, operation|
        accessor = "#{callback}_for_#{name}"
        model.class_attribute(accessor, instance_accessor: false, instance_predicate: false) unless model.respond_to?(accessor)
        recorder = ->(_method, owner, record) { Provenance::Recorder.association(owner, name, record, operation) }
        model.public_send(:"#{accessor}=", Array(model.public_send(accessor)) + [recorder])
      end
    end
  end
end

ActiveSupport.on_load(:active_record) { extend Provenance::Model::ClassMethods }
