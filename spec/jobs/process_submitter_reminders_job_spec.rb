# frozen_string_literal: true

require 'rails_helper'
require 'sidekiq/api'

RSpec.describe ProcessSubmitterRemindersJob do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:template) { create(:template, submitter_count: 2, account:, author: user) }
  let(:submission) { create(:submission, :with_submitters, template:, created_by_user: user) }
  let(:signer) { submission.submitters.find { |s| s.uuid == template.submitters.first['uuid'] } }
  let(:viewer) { submission.submitters.find { |s| s.uuid == template.submitters.second['uuid'] } }

  before do
    template.update!(submitters: [template.submitters.first, template.submitters.second.merge('is_viewer' => true)])

    create(:account_config, account:, key: AccountConfig::SUBMITTER_REMINDERS,
                            value: { 'first_duration' => 'one_hour' })

    submission.submitters.each { |submitter| submitter.update!(sent_at: 2.hours.ago) }

    allow(Sidekiq::ScheduledSet).to receive(:new).and_return([])
  end

  describe '#perform' do
    it 'enqueues a reminder for the signing party' do
      described_class.new.perform

      submitter_ids = SendSubmitterReminderEmailJob.jobs.map { |job| job['args'].first['submitter_id'] }

      expect(submitter_ids).to include(signer.id)
    end

    it 'does not enqueue a reminder for a viewer party' do
      expect(viewer).to be_viewer

      described_class.new.perform

      submitter_ids = SendSubmitterReminderEmailJob.jobs.map { |job| job['args'].first['submitter_id'] }

      expect(submitter_ids).not_to include(viewer.id)
    end
  end
end
