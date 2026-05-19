require 'rails_helper'

describe Server do

  context "model" do
    subject(:server) { create(:server) }

    it "should have a UUID" do
      expect(server.uuid).to be_a String
      expect(server.uuid.length).to eq 36
    end
  end

  context "default IP pools" do
    let(:org) { create(:organization) }
    let(:server) { create(:server, organization: org) }

    it "returns empty when no default pools configured" do
      allow(Postal).to receive(:default_ip_pool_names).and_return([])
      expect(server.default_ip_pools).to eq([])
    end

    it "returns pools matching configured names" do
      pool1 = create(:ip_pool, name: "global-1")
      pool2 = create(:ip_pool, name: "global-2")
      allow(Postal).to receive(:ip_pools?).and_return(true)
      allow(Postal).to receive(:default_ip_pool_names).and_return(["global-1", "global-2"])
      expect(server.default_ip_pools).to match_array([pool1, pool2])
    end

    it "falls back to default pool in ip_pool_for_message when server/org pools missing" do
      default_pool = create(:ip_pool, name: "fallback")
      allow(Postal).to receive(:ip_pools?).and_return(true)
      allow(Postal).to receive(:default_ip_pool_names).and_return(["fallback"])
      message = double('message', scope: 'outgoing')
      expect(server.ip_pool_for_message(message)).to eq(default_pool)
    end

    it "prioritizes server pool over default" do
      server_pool = create(:ip_pool)
      default_pool = create(:ip_pool, name: "fallback")
      allow(Postal).to receive(:ip_pools?).and_return(true)
      allow(Postal).to receive(:default_ip_pool_names).and_return(["fallback"])
      server.update(ip_pool: server_pool)
      message = double('message', scope: 'outgoing')
      expect(server.ip_pool_for_message(message)).to eq(server_pool)
    end

    it "includes default pools in ip_pools_with_defaults" do
      default_pool = create(:ip_pool, name: "global")
      allow(Postal).to receive(:ip_pools?).and_return(true)
      allow(Postal).to receive(:default_ip_pool_names).and_return(["global"])
      expect(server.ip_pools_with_defaults).to include(default_pool)
    end
  end

  context "sender authorization" do
    let(:org) { create(:organization) }
    let(:server) { create(:server, organization: org) }
    let(:domain) { create(:domain, owner: server, name: 'bammby.com') }

    it "allows exact route sender addresses" do
      Route.create!(server: server, domain: domain, name: 'support', mode: 'Accept', spam_mode: 'Mark')

      expect(server.sender_address_authorized?('Support <support@bammby.com>')).to be true
    end

    it "does not treat wildcard routes as proof that a sender address exists" do
      Route.create!(server: server, domain: domain, name: '*', mode: 'Accept', spam_mode: 'Mark')

      expect(server.sender_address_authorized?('alex@bammby.com')).to be false
    end
  end

end
