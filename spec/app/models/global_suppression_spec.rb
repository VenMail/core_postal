require 'rails_helper'

RSpec.describe GlobalSuppression, type: :model do
  describe 'validations' do
    it 'is valid with valid attributes' do
      global_suppression = GlobalSuppression.new(
        ip_address: '192.168.1.1',
        reason: 'Test ban'
      )
      expect(global_suppression).to be_valid
    end

    it 'is invalid without ip_address' do
      global_suppression = GlobalSuppression.new(
        ip_address: nil,
        reason: 'Test ban'
      )
      expect(global_suppression).not_to be_valid
      expect(global_suppression.errors[:ip_address]).to include("can't be blank")
    end

    it 'is invalid without reason' do
      global_suppression = GlobalSuppression.new(
        ip_address: '192.168.1.1',
        reason: nil
      )
      expect(global_suppression).not_to be_valid
      expect(global_suppression.errors[:reason]).to include("can't be blank")
    end

    it 'is invalid with duplicate ip_address' do
      GlobalSuppression.create!(
        ip_address: '192.168.1.1',
        reason: 'First ban'
      )
      
      duplicate = GlobalSuppression.new(
        ip_address: '192.168.1.1',
        reason: 'Duplicate ban'
      )
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:ip_address]).to include("has already been taken")
    end
  end

  describe 'callbacks' do
    it 'normalizes IP address before validation' do
      global_suppression = GlobalSuppression.new(
        ip_address: '  192.168.1.1  ',
        reason: 'Test ban'
      )
      global_suppression.valid?
      expect(global_suppression.ip_address).to eq('192.168.1.1')
    end

    it 'normalizes IPv6 address casing' do
      global_suppression = GlobalSuppression.new(
        ip_address: '  2001:DB8::1  ',
        reason: 'Test ban'
      )
      global_suppression.valid?
      expect(global_suppression.ip_address).to eq('2001:db8::1')
    end
  end

  describe 'scopes' do
    before do
      @permanent_ban = GlobalSuppression.create!(
        ip_address: '192.168.1.1',
        reason: 'Permanent ban',
        keep_until: nil
      )
      
      @active_ban = GlobalSuppression.create!(
        ip_address: '192.168.1.2',
        reason: 'Active ban',
        keep_until: 1.hour.from_now
      )
      
      @expired_ban = GlobalSuppression.create!(
        ip_address: '192.168.1.3',
        reason: 'Expired ban',
        keep_until: 1.hour.ago
      )
    end

    describe '.active' do
      it 'includes permanent bans (keep_until: nil)' do
        active_suppressions = GlobalSuppression.active
        expect(active_suppressions).to include(@permanent_ban)
      end

      it 'includes bans that have not expired yet' do
        active_suppressions = GlobalSuppression.active
        expect(active_suppressions).to include(@active_ban)
      end

      it 'excludes expired bans' do
        active_suppressions = GlobalSuppression.active
        expect(active_suppressions).not_to include(@expired_ban)
      end
    end

    describe '.by_ip' do
      it 'finds suppression by IP address' do
        result = GlobalSuppression.by_ip('192.168.1.1')
        expect(result).to include(@permanent_ban)
      end

      it 'returns empty result for non-existent IP' do
        result = GlobalSuppression.by_ip('10.0.0.1')
        expect(result).to be_empty
      end
    end
  end

  describe 'instance methods' do
    describe '#active?' do
      it 'returns true for permanent bans' do
        permanent_ban = GlobalSuppression.create!(
          ip_address: '192.168.1.1',
          reason: 'Permanent ban',
          keep_until: nil
        )
        expect(permanent_ban).to be_active
      end

      it 'returns true for bans that have not expired' do
        active_ban = GlobalSuppression.create!(
          ip_address: '192.168.1.2',
          reason: 'Active ban',
          keep_until: 1.hour.from_now
        )
        expect(active_ban).to be_active
      end

      it 'returns false for expired bans' do
        expired_ban = GlobalSuppression.create!(
          ip_address: '192.168.1.3',
          reason: 'Expired ban',
          keep_until: 1.hour.ago
        )
        expect(expired_ban).not_to be_active
      end
    end
  end

  describe 'class methods' do
    describe '.ban_ip' do
      it 'creates a new permanent ban for valid IP' do
        result = GlobalSuppression.ban_ip('192.168.1.1', reason: 'Test ban')
        expect(result).to be_truthy
        
        ban = GlobalSuppression.find_by(ip_address: '192.168.1.1')
        expect(ban).not_to be_nil
        expect(ban.reason).to eq('Test ban')
        expect(ban.keep_until).to be_nil
      end

      it 'returns false for invalid IP' do
        result = GlobalSuppression.ban_ip('', reason: 'Test ban')
        expect(result).to be_falsey
      end

      it 'normalizes IPv4-mapped IPv6 addresses before creating a ban' do
        GlobalSuppression.ban_ip('::ffff:204.10.162.167', reason: 'Mapped IP ban')
        expect(GlobalSuppression.find_by(ip_address: '204.10.162.167')).to be_present
      end

      it 'returns existing ban if IP already banned' do
        GlobalSuppression.ban_ip('192.168.1.1', reason: 'First ban')
        
        result = GlobalSuppression.ban_ip('192.168.1.1', reason: 'Second ban')
        expect(result).to be_truthy
        
        bans = GlobalSuppression.where(ip_address: '192.168.1.1')
        expect(bans.count).to eq(1)
        expect(bans.first.reason).to eq('First ban')
      end

      it 'uses default reason if none provided' do
        GlobalSuppression.ban_ip('192.168.1.1')
        ban = GlobalSuppression.find_by(ip_address: '192.168.1.1')
        expect(ban.reason).to eq('Manual IP ban')
      end
    end

    describe '.unban_ip' do
      it 'removes existing ban' do
        GlobalSuppression.ban_ip('192.168.1.1', reason: 'Test ban')
        result = GlobalSuppression.unban_ip('192.168.1.1')
        expect(result).to be_truthy
        expect(GlobalSuppression.find_by(ip_address: '192.168.1.1')).to be_nil
      end

      it 'returns false for non-existent ban' do
        result = GlobalSuppression.unban_ip('192.168.1.1')
        expect(result).to be_falsey
      end

      it 'returns false for invalid IP' do
        result = GlobalSuppression.unban_ip('')
        expect(result).to be_falsey
      end
    end

    describe '.ip_banned?' do
      it 'returns true for banned IP' do
        GlobalSuppression.ban_ip('192.168.1.1', reason: 'Test ban')
        expect(GlobalSuppression.ip_banned?('192.168.1.1')).to be_truthy
      end

      it 'matches IPv4-mapped IPv6 client addresses against IPv4 bans' do
        GlobalSuppression.ban_ip('204.10.162.167', reason: 'Test ban')
        expect(GlobalSuppression.ip_banned?('::ffff:204.10.162.167')).to be_truthy
      end

      it 'matches CIDR bans' do
        GlobalSuppression.ban_ip('204.10.162.0/24', reason: 'Network ban')
        expect(GlobalSuppression.ip_banned?('204.10.162.167')).to be_truthy
      end

      it 'returns false for non-banned IP' do
        expect(GlobalSuppression.ip_banned?('192.168.1.1')).to be_falsey
      end

      it 'returns false for invalid IP' do
        expect(GlobalSuppression.ip_banned?('')).to be_falsey
        expect(GlobalSuppression.ip_banned?(nil)).to be_falsey
      end

      it 'returns false for expired bans' do
        GlobalSuppression.create!(
          ip_address: '192.168.1.1',
          reason: 'Expired ban',
          keep_until: 1.hour.ago
        )
        expect(GlobalSuppression.ip_banned?('192.168.1.1')).to be_falsey
      end
    end

    describe '.prune_expired' do
      it 'removes all expired bans' do
        GlobalSuppression.create!(
          ip_address: '192.168.1.1',
          reason: 'Permanent ban',
          keep_until: nil
        )
        GlobalSuppression.create!(
          ip_address: '192.168.1.2',
          reason: 'Active ban',
          keep_until: 1.hour.from_now
        )
        GlobalSuppression.create!(
          ip_address: '192.168.1.3',
          reason: 'Expired ban',
          keep_until: 1.hour.ago
        )
        
        expect(GlobalSuppression.count).to eq(3)
        
        result = GlobalSuppression.prune_expired
        expect(result).to be_an(Array)
        expect(result.count).to eq(1)  # Should destroy 1 expired record
        
        expect(GlobalSuppression.count).to eq(2)
        expect(GlobalSuppression.find_by(ip_address: '192.168.1.1')).not_to be_nil  # Permanent remains
        expect(GlobalSuppression.find_by(ip_address: '192.168.1.2')).not_to be_nil  # Active remains
        expect(GlobalSuppression.find_by(ip_address: '192.168.1.3')).to be_nil      # Expired removed
      end

      it 'returns empty array when no expired bans exist' do
        GlobalSuppression.create!(
          ip_address: '192.168.1.1',
          reason: 'Permanent ban',
          keep_until: nil
        )
        
        result = GlobalSuppression.prune_expired
        expect(result).to be_an(Array)
        expect(result).to be_empty
        expect(GlobalSuppression.count).to eq(1)
      end
    end
  end

  describe 'IP address normalization' do
    describe '.normalize_ip_address_string' do
      it 'returns nil for blank IP' do
        expect(GlobalSuppression.normalize_ip_address_string('')).to be_nil
        expect(GlobalSuppression.normalize_ip_address_string(nil)).to be_nil
        expect(GlobalSuppression.normalize_ip_address_string('   ')).to be_nil
      end

      it 'strips whitespace' do
        result = GlobalSuppression.normalize_ip_address_string('  192.168.1.1  ')
        expect(result).to eq('192.168.1.1')
      end

      it 'normalizes IPv4-mapped IPv6 to native IPv4' do
        result = GlobalSuppression.normalize_ip_address_string('::ffff:204.10.162.167')
        expect(result).to eq('204.10.162.167')
      end

      it 'handles exceptions gracefully' do
        # This should not raise an exception
        expect { GlobalSuppression.normalize_ip_address_string('invalid') }.not_to raise_error
        expect(GlobalSuppression.normalize_ip_address_string('invalid')).to be_nil
      end
    end
  end
end
