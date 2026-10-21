# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SubmitterReminders do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:template) { create(:template, submitter_count: 2, account:, author: user) }
  let(:submission) { create(:submission, :with_submitters, template:, created_by_user: user) }
  let(:reminder_config) do
    create(:account_config, account:, key: AccountConfig::SUBMITTER_REMINDERS,
                            value: { 'first_duration' => 'one_hour' })
  end

  before do
    template.update!(submitters: [template.submitters.first, template.submitters.second.merge('is_viewer' => true)])

    submission.submitters.each { |submitter| submitter.update!(sent_at: 2.hours.ago) }
  end

  describe '.next_reminder_at' do
    it 'returns the next reminder time for a signing party' do
      signer = submission.submitters.find { |s| s.uuid == template.submitters.first['uuid'] }

      expect(described_class.next_reminder_at(signer, reminder_config))
        .to be_within(1.second).of(signer.sent_at + 1.hour)
    end

    it 'returns nil for a viewer party' do
      viewer = submission.submitters.find { |s| s.uuid == template.submitters.second['uuid'] }

      expect(described_class.next_reminder_at(viewer, reminder_config)).to be_nil
    end
  end
end
