# frozen_string_literal: true

RSpec.describe "ActiveJob capture" do
  include ActiveJob::TestHelper

  let(:user) { User.create!(email: "u@example.com") }
  let(:invoice) { Provenance.without { Invoice.create!(number: "1") } }

  it "carries the enqueuing action id and actor in the job payload" do
    parent_id = nil
    Provenance.action("invoices.send", actor: user) do
      parent_id = Provenance.current.id
      SendInvoiceJob.perform_later(invoice.id)
    end

    job_data = enqueued_jobs.sole
    expect(job_data["provenance"]).to eq(
      "action_id" => parent_id,
      "actor" => {"id" => user.id.to_s, "type" => "User", "display" => "u@example.com", "roles" => [], "impersonator" => nil}
    )

    perform_enqueued_jobs
    event = events.last
    expect(event["action"]).to eq("kind" => "job", "name" => "SendInvoiceJob", "caused_by" => parent_id)
    expect(event["actor"]["id"]).to eq(user.id.to_s)
    expect(event["changes"].sole["diff"]).to eq("status" => %w[draft sent])
    expect(schema_errors(event)).to be_empty
  end

  it "runs jobs enqueued outside an action without a parent" do
    SendInvoiceJob.perform_later(invoice.id)
    expect(enqueued_jobs.sole).not_to have_key("provenance")
    perform_enqueued_jobs
    expect(events.sole["action"]["caused_by"]).to be_nil
  end

  it "records failures and re-raises" do
    expect { FailingJob.perform_now }.to raise_error(RuntimeError, "job failed")
    expect(events.sole["outcome"]).to eq("result" => "failure", "error" => {"class" => "RuntimeError", "message" => "job failed"})
  end

  it "skips successful jobs without changes" do
    job = Class.new(ActiveJob::Base) do
      def self.name = "NoopJob"

      def perform = nil
    end
    job.perform_now
    expect(events).to be_empty
  end

  it "honours skip_provenance" do
    QuietJob.perform_now(invoice.id)
    expect(events).to be_empty
    expect(invoice.reload.status).to eq("quiet")
  end

  it "attaches jobs performed inline to the open action" do
    Provenance.action("inline") { SendInvoiceJob.perform_now(invoice.id) }
    expect(events.sole["action"]["name"]).to eq("inline")
    expect(events.sole["changes"].size).to eq(1)
  end

  it "passes the job to the actor resolver" do
    Provenance.config.actor { |ctx| ctx.job && {id: ctx.job.job_id, type: "Job"} }
    SendInvoiceJob.perform_now(invoice.id)
    expect(events.sole["actor"]["type"]).to eq("Job")
  end
end
