require 'spec_helper'
require 'open3'
require 'openssl'
require 'rbconfig'
require 'tmpdir'

RSpec.describe 'script/generate_initial_config.rb' do
  let(:script_path) { File.expand_path('../../script/generate_initial_config.rb', __dir__) }

  def run_generator(config_root)
    stdout, stderr, status = Open3.capture3(
      {
        'POSTAL_CONFIG_ROOT' => config_root,
        'POSTAL_ENV' => 'default'
      },
      RbConfig.ruby,
      script_path
    )

    expect(status).to be_success, "Generator failed:\n#{stdout}\n#{stderr}"
  end

  def write_config_file(config_root)
    File.write(File.join(config_root, 'postal.yml'), "{}\n")
  end

  it 'creates an RSA signing key with at least 2048 bits when one is missing' do
    Dir.mktmpdir('postal-config') do |config_root|
      write_config_file(config_root)
      run_generator(config_root)

      key = OpenSSL::PKey::RSA.new(File.binread(File.join(config_root, 'signing.key')))

      expect(key.private?).to be(true)
      expect(key.n.num_bits).to be >= 2048
    end
  end

  it 'does not rotate an existing signing key' do
    Dir.mktmpdir('postal-config') do |config_root|
      write_config_file(config_root)
      existing_key = OpenSSL::PKey::RSA.new(1024).to_s
      File.binwrite(File.join(config_root, 'signing.key'), existing_key)

      run_generator(config_root)

      expect(File.binread(File.join(config_root, 'signing.key'))).to eq(existing_key)
    end
  end
end
