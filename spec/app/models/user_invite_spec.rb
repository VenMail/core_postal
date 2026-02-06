require 'rails_helper'

RSpec.describe UserInvite, type: :model do
  describe 'associations' do
    it 'has many organizations' do
      expect(UserInvite.new).to have_many(:organizations).through(:organization_users)
    end

    it 'has many organization_users' do
      expect(UserInvite.new).to have_many(:organization_users).dependent(:destroy)
    end
  end

  describe 'validations' do
    it 'is valid with valid attributes' do
      user_invite = UserInvite.new(
        email_address: 'test@example.com'
      )
      expect(user_invite).to be_valid
    end

    it 'is invalid without email_address' do
      user_invite = UserInvite.new(
        email_address: nil
      )
      expect(user_invite).not_to be_valid
      expect(user_invite.errors[:email_address]).to include("can't be blank")
    end

    it 'is invalid with invalid email format' do
      user_invite = UserInvite.new(
        email_address: 'invalid-email'
      )
      expect(user_invite).not_to be_valid
      expect(user_invite.errors[:email_address]).to include("is invalid")
    end

    it 'is invalid with duplicate email_address' do
      UserInvite.create!(email_address: 'test@example.com')
      duplicate = UserInvite.new(email_address: 'test@example.com')
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:email_address]).to include("has already been taken")
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
    describe '.active' do
      it 'returns only active invites' do
        active_invite = create(:user_invite, :expires_at => 1.hour.from_now)
        expired_invite = create(:user_invite, :expires_at => 1.hour.ago)
        
        active_invites = UserInvite.active
        expect(active_invites).to include(active_invite)
        expect(active_invites).not_to include(expired_invite)
      end
    end
  end

  describe 'instance methods' do
    let(:user_invite) { create(:user_invite) }

    describe '#accept' do
      it 'transfers organization_users to user and destroys invite' do
        user = create(:user)
        organization = create(:organization)
        user_invite.organizations << organization
        
        expect(UserInvite.count).to eq(1)
        expect(OrganizationUser.count).to eq(1)
        
        user_invite.accept(user)
        
        expect(UserInvite.count).to eq(0)
        expect(OrganizationUser.count).to eq(1)
        expect(user.organizations).to include(organization)
      end
    end

    describe '#reject' do
      it 'destroys the invite' do
        expect(UserInvite.count).to eq(1)
        user_invite.reject
        expect(UserInvite.count).to eq(0)
      end
    end

    describe '#name' do
      it 'returns email_address' do
        user_invite.email_address = 'test@example.com'
        expect(user_invite.name).to eq('test@example.com')
      end
    end

    describe '#avatar_url' do
      it 'returns gravatar URL for email address' do
        user_invite.email_address = 'test@example.com'
        expected_url = "https://secure.gravatar.com/avatar/#{Digest::MD5.hexdigest('test@example.com')}?rating=PG&size=120&d=mm"
        expect(user_invite.avatar_url).to eq(expected_url)
      end

      it 'returns nil for blank email address' do
        user_invite.email_address = ''
        expect(user_invite.avatar_url).to be_nil
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
