# frozen_string_literal: true

module Provenance
  # Base class for all Provenance errors.
  class Error < StandardError; end

  # Raised when {Configuration#validate!} finds an invalid setting.
  class ConfigurationError < Error; end

  # Raised by sinks when an event batch could not be delivered.
  class DeliveryError < Error; end
end
