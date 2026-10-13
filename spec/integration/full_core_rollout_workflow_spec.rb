require 'spec_helper'

RSpec.describe 'full Core rollout workflow' do
  let(:workflow_path) do
    ENV.fetch('FULL_CORE_WORKFLOW_SOURCE', File.expand_path('../../.github/workflows/deploy-core-full.yml', __dir__))
  end
  let(:workflow) do
    File.read(workflow_path)
  end

  before do
    skip 'workflow metadata is excluded from the application test image' unless File.exist?(workflow_path)
  end

  it 'deploys the SMTP service with the workers that enforce abuse controls' do
    expect(workflow).to include('web core worker cron requeuer smtp')
  end

  it 'refuses a rollout when production spam evaluation is disabled' do
    expect(workflow).to include('spam_check_enabled')
    expect(workflow).to include('/opt/venmail/bconfig/postal.yml')
    expect(workflow).to include('/opt/venmail/cconfig/postal.yml')
    expect(workflow).to include('Spam evaluation must be enabled before a full Core rollout.')
  end

  it 'verifies every delivery component is running the approved immutable image' do
    expect(workflow).to include('install-smtp-1')
    expect(workflow).to include('install-worker-1')
  end

  it 'verifies abuse configuration inside every restarted Core service' do
    expect(workflow).to match(/for container in install-web-1 install-core-1 install-worker-1 install-cron-1 install-requeuer-1 install-smtp-1; do\s+actual_spam_setting=/m)
  end
end
