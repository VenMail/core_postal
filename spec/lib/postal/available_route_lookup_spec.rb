require 'rails_helper'

describe Postal::AvailableRouteLookup do
  before do
    allow(described_class).to receive(:urls).and_return([
      'https://first.example.test/api/v1/checkalias',
      'https://second.example.test/api/v1/checkalias'
    ])
  end

  it "continues to later lookup URLs when an earlier URL reports not found" do
    allow(Postal::HTTP).to receive(:get).and_return(
      { :code => 200, :body => { :found => false }.to_json },
      { :code => 200, :body => { :found => true, :main_email => 'support@example.com' }.to_json }
    )

    expect(described_class.lookup('alias@example.com')).to eq(
      'found' => true,
      'main_email' => 'support@example.com'
    )
  end

  it "returns a not found response when no lookup URL has the alias" do
    allow(Postal::HTTP).to receive(:get).and_return(
      { :code => 200, :body => { :found => false }.to_json },
      { :code => 502, :body => 'bad gateway' }
    )

    expect(described_class.lookup('alias@example.com')).to eq('found' => false)
  end
end
