# frozen_string_literal: true

RSpec.describe 'Submission' do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:template) { create(:template, account:, author: user) }
  let(:submission) do
    create(:submission, :with_submitters, template:, created_by_user: user,
                                          archived_at: Time.current, completed_at: Time.current)
  end

  before do
    sign_in(user)
    submission.submitters.each { |s| s.update!(completed_at: 1.day.ago) }
  end

  it 'unarchives a completed submission from the download dropdown' do
    visit submission_path(submission)

    find('label[aria-label="Download"]').click
    click_button 'Unarchive'

    expect(page).to have_content('Submission has been unarchived.')
    expect(submission.reload.archived_at).to be_nil
  end

  context 'with a reminder config and a pending signer' do
    let(:pending_template) { create(:template, submitter_count: 2, account:, author: user) }
    let(:pending_submission) do
      create(:submission, :with_submitters, template: pending_template, created_by_user: user)
    end

    before do
      pending_template.update!(submitters: [pending_template.submitters.first,
                                            pending_template.submitters.second.merge('is_viewer' => true)])

      create(:account_config, account:, key: AccountConfig::SUBMITTER_REMINDERS,
                              value: { 'first_duration' => 'one_hour' })

      pending_submission.submitters.each do |submitter|
        name = submitter.uuid == pending_template.submitters.first['uuid'] ? 'Pending Signer' : 'Document Viewer'

        submitter.update!(name:, sent_at: 30.minutes.ago)
      end
    end

    it 'shows the next reminder for the signer only' do
      visit submission_path(pending_submission)

      within('#parties_view') do
        expect(find('.group', text: 'Pending Signer')).to have_content('Next reminder: in')
        expect(find('.group', text: 'Document Viewer')).to have_no_content('Next reminder')
      end
    end
  end
end
