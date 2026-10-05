# frozen_string_literal: true

require "rake"

RSpec.describe Provenance::Rake do
  let(:rake) { Rake::Application.new }

  before do
    described_class.install!
    Rake.application = rake
  end

  it "wraps task execution in a task action" do
    Rake::Task.define_task(:prepare) { Invoice.create!(number: "pre") }
    Rake::Task.define_task(import: :prepare) { Invoice.create!(number: "main") }
    Rake::Task[:import].invoke

    expect(events.size).to eq(2)
    expect(events.map { |e| e["action"]["kind"] }.uniq).to eq(["task"])
    expect(events.map { |e| e["action"]["name"] }).to eq(%w[prepare import])
  end

  it "attaches nested invocations to the running task" do
    Rake::Task.define_task(:inner) { Invoice.create!(number: "inner") }
    Rake::Task.define_task(:outer) do
      Invoice.create!(number: "outer")
      Rake::Task[:inner].invoke
    end
    Rake::Task[:outer].invoke

    expect(events.sole["action"]["name"]).to eq("outer")
    expect(events.sole["changes"].size).to eq(2)
  end

  it "records failures and re-raises" do
    Rake::Task.define_task(:explode) { raise "rake failed" }
    expect { Rake::Task[:explode].invoke }.to raise_error("rake failed")
    expect(events.sole["outcome"]["result"]).to eq("failure")
  end

  it "is idempotent" do
    described_class.install!
    expect(Rake::Task.ancestors.count(Provenance::Rake::TaskExtension)).to eq(1)
  end
end
