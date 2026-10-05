# frozen_string_literal: true

ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :users, force: true do |t|
    t.string :email
    t.string :role
  end

  create_table :invoices, force: true do |t|
    t.string :number
    t.string :status, default: "draft"
    t.decimal :amount, precision: 10, scale: 2
    t.text :notes
    t.string :iban
    t.string :password_hint
    t.datetime :paid_at
    t.binary :attachment
    t.timestamps
  end

  create_table :tags, force: true do |t|
    t.string :name
  end

  create_table :taggings, force: true do |t|
    t.references :invoice
    t.references :tag
  end

  create_table :accounts, force: true do |t|
    t.string :name
    t.integer :balance, default: 0
    t.string :secret_code
  end

  create_table :documents, force: true do |t|
    t.string :type
    t.string :title
    t.string :body
  end

  create_table :vaults, force: true do |t|
    t.string :name
    t.string :pin
  end

  create_table :notes, force: true do |t|
    t.string :body
  end

  create_table :provenance_outbox, force: true do |t|
    t.string :app, null: false
    t.string :event_id, null: false
    t.bigint :seq
    t.string :mac
    t.text :payload, null: false
    t.string :status, null: false, default: "pending"
    t.integer :attempts, null: false, default: 0
    t.datetime :next_attempt_at
    t.datetime :delivered_at
    t.text :last_error
    t.timestamps
  end
  add_index :provenance_outbox, %i[status id]
  add_index :provenance_outbox, %i[app seq], unique: true
end
