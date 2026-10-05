# frozen_string_literal: true

class SendInvoiceJob < ActiveJob::Base
  def perform(invoice_id)
    Invoice.find(invoice_id).update!(status: "sent")
  end
end

class FailingJob < ActiveJob::Base
  def perform
    raise "job failed"
  end
end

class QuietJob < ActiveJob::Base
  skip_provenance

  def perform(invoice_id)
    Invoice.find(invoice_id).update!(status: "quiet")
  end
end
