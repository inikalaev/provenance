# frozen_string_literal: true

class User < ActiveRecord::Base
  def provenance_roles
    [role].compact
  end
end

class Tag < ActiveRecord::Base
end

class Tagging < ActiveRecord::Base
  belongs_to :invoice
  belongs_to :tag
end

class Invoice < ActiveRecord::Base
  has_many :taggings, dependent: :delete_all
  has_many :tags, through: :taggings

  has_provenance redact: %i[notes], associations: %i[tags], ignore_if: ->(invoice) { invoice.number == "IGNORED" }
end

class Account < ActiveRecord::Base
  has_provenance only: %i[name balance secret_code]
end

class Document < ActiveRecord::Base
  has_provenance except: %i[body]
end

class Memo < Document
end

class Vault < ActiveRecord::Base
  encrypts :pin
  has_provenance
end

class Note < ActiveRecord::Base
end
