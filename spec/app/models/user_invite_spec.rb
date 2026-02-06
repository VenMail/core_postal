require 'rails_helper'

RSpec.describe UserInvite, type: :model do
  describe 'associations' do
    it 'belongs to organization' do
      expect(UserInvite.new).to belong_to(:organization)
    end

    it 'belongs to user (optional)' do
      expect(UserInvite.new).to belong_to(:user).optional
    end
  end

  describe 'validations' do
    it 'is valid with valid attributes' do
      user_invite = UserInvite.new(
        organization: create(:organization),
        email_address: 'test@example.com'
      )
      expect(user_invite).to be_valid
    end

    it 'is invalid without organization' do
      user_invite = UserInvite.new(
        organization: nil,
        email_address: 'test@example.com'
      )
      expect(user_invite).not_to be_valid
    end

    it 'is invalid without email_address' do
      user_invite = UserInvite.new(
        organization: create(:organization),
        email_address: nil
      )
      expect(user_invite).not_to be_valid
    end
  end

  describe 'scopes' do
    describe '.active' do
      it 'includes invites that have not expired' do
        active_invite = create(:user_invite, :expires_at => 1.hour.from_now)
        expired_invite = create(:user_invite, :expires_at => 1.hour.ago)
        
        active_invites = UserInvite.active
        expect(active_invites).to include(active_invite)
        expect(active_invites).not_to include(expired_invite)
      end
    end
  end

  describe 'default values' do
    it 'sets expires_at to 7 days from now by default' do
      user_invite = UserInvite.new
      expected_time = 7.days.from_now
      expect(user_invite.expires_at).to be_within(1.minute).of(expected_time)
    end
  end

  describe 'instance methods' do
    let(:user_invite) { create(:user_invite) }

    describe '#md5_for_gravatar' do
      it 'generates MD5 hash for email address' do
        user_invite.email_address = 'Test@Example.COM'
        expected_md5 = Digest::MD5.hexdigest('test@example.com'.downcase)
        expect(user_invite.md5_for_gravatar).to eq(expected_md5)
      end

      it 'returns same MD5 for same email' do
        user_invite.email_address = 'test@example.com'
        md5_1 = user_invite.md5_for_gravatar
        md5_2 = user_invite.md5_for_gravatar
        expect(md5_1).to eq(md5_2)
      end

      it 'handles blank email addresses' do
        user_invite.email_address = ''
        md5 = user_invite.md5_for_gravatar
        expect(md5).to eq(Digest::MD5.hexdigest(''))
      end
    end
  end

  describe 'class methods' do
    describe '.expired' do
      it 'returns expired invites' do
        active_invite = create(:user_invite, :expires_at => 1.hour.from_now)
        expired_invite = create(:user_invite, :expires_at => 1.hour.ago)
        
        expired_invites = UserInvite.expired
        expect(expired_invites).to include(expired_invite)
        expect(expired_invites).not_to include(active_invite)
      end
    end

    describe '.prune_expired' do
      it 'removes all expired invites' do
        active_invite = create(:user_invite, :expires_at => 1.hour.from_now)
        expired_invite = create(:user_invite, :expires_at => 1.hour.ago)
        
        expect(UserInvite.count).to eq(2)
        
        result = UserInvite.prune_expired
        expect(result).to eq(1)  # Should destroy 1 expired record
        
        expect(UserInvite.count).to eq(1)
        expect(UserInvite.find_by(id: active_invite.id)).not_to be_nil
        expect(UserInvite.find_by(id: expired_invite.id)).to be_nil
      end

      it 'returns 0 when no expired invites exist' do
        active_invite = create(:user_invite, :expires_at => 1.hour.from_now)
        
        result = UserInvite.prune_expired
        expect(result).to eq(0)
        expect(UserInvite.count).to eq(1)
      end
    end
  end

  describe 'email address normalization' do
    it 'downcases email addresses' do
      user_invite = create(:user_invite, :email_address => 'Test@Example.COM')
      expect(user_invite.email_address).to eq('test@example.com')
    end

    it 'strips whitespace from email addresses' do
      user_invite = create(:user_invite, :email_address => '  test@example.com  ')
      expect(user_invite.email_address).to eq('test@example.com')
    end
  end

  describe 'token generation' do
    it 'generates a unique token on creation' do
      invite1 = create(:user_invite)
      invite2 = create(:user_invite)
      
      expect(invite1.token).not_to be_nil
      expect(invite2.token).not_to be_nil
      expect(invite1.token).not_to eq(invite2.token)
    end

    it 'generates tokens of reasonable length' do
      user_invite = create(:user_invite)
      expect(user_invite.token.length).to be_between(20, 50)
    end
  end
end
