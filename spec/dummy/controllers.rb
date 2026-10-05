# frozen_string_literal: true

module Pundit
  class NotAuthorizedError < StandardError; end
end

class ApplicationController < ActionController::Base
  skip_forgery_protection

  def current_user
    @current_user ||= User.find_by(id: request.headers["X-User-Id"])
  end
end

class InvoicesController < ApplicationController
  class Forbidden < StandardError; end

  rescue_from Forbidden, with: -> { head :forbidden }

  def index
    render plain: Invoice.pluck(:id).join(",")
  end

  def show
    render plain: Invoice.find(params[:id]).number
  end

  def peek
    Invoice.find(params[:id]).update!(status: "peeked")
    head :ok
  end

  def create
    invoice = Invoice.create!(params.require(:invoice).permit(:number, :status, :amount, :notes))
    render plain: invoice.id.to_s, status: :created
  end

  def update
    invoice = Invoice.find(params[:id])
    invoice.update!(params.require(:invoice).permit(:status, :amount, :notes))
    Provenance.current&.annotate(reason: params[:reason]) if params[:reason]
    render plain: invoice.id.to_s
  end

  def destroy
    Invoice.find(params[:id]).destroy!
    head :no_content
  end

  def boom
    Invoice.find(params[:id]).update!(status: "exploding")
    raise ArgumentError, "kaboom " * 200
  end

  def forbidden
    raise Pundit::NotAuthorizedError, "not allowed"
  end

  def rescued_forbidden
    raise Forbidden
  end

  def tag
    Invoice.find(params[:id]).tags << Tag.find_or_create_by!(name: params[:name])
    head :ok
  end
end

class HealthController < ApplicationController
  skip_provenance only: :create

  def show
    head :ok
  end

  def create
    Note.create!(body: "health")
    head :ok
  end
end

module Admin
  class ReportsController < ApplicationController
    provenance_action_name ->(controller) { "admin.reports.#{controller.action_name}" }

    def create
      head :ok
    end

    def preview
      head :ok
    end
  end
end
