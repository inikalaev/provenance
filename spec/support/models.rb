# frozen_string_literal: true

class User < ActiveRecord::Base
  include Provenance::Trackable

  has_many :posts, dependent: :destroy
  has_many :comments, dependent: :destroy

  sensitive_attributes :password

  validates :email, presence: true
end

class Tag < ActiveRecord::Base
  include Provenance::Trackable
end

class Post < ActiveRecord::Base
  include Provenance::Trackable

  belongs_to :user
  has_many :comments, dependent: :destroy
  has_and_belongs_to_many :tags

  acts_as_list scope: :user_id
end

class Comment < ActiveRecord::Base
  include Provenance::Trackable

  belongs_to :post
  belongs_to :user

  acts_as_list scope: :post_id
end

class Category < ActiveRecord::Base
  include Provenance::Trackable

  acts_as_list
end
