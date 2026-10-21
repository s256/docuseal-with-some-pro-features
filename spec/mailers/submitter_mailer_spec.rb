# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SubmitterMailer do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:template) { create(:template, submitter_count: 2, account:, author: user) }
  let(:submission) { create(:submission, :with_submitters, template:, created_by_user: user) }
  let(:signer) { submission.submitters.find { |s| s.uuid == template.submitters.first['uuid'] } }
  let(:viewer) { submission.submitters.find { |s| s.uuid == template.submitters.second['uuid'] } }

  before do
    template.update!(submitters: [template.submitters.first, template.submitters.second.merge('is_viewer' => true)])
  end

  def email_button(mail, submitter)
    html = mail.html_part ? mail.html_part.body.decoded : mail.body.decoded

    Nokogiri::HTML(html).css("td[style*='background-color'] > a[href*='/s/#{submitter.slug}']")
  end

  describe '#invitation_view_email' do
    it 'renders a View Document button for the viewer' do
      mail = described_class.invitation_view_email(viewer)

      expect(viewer).to be_viewer
      expect(email_button(mail, viewer).map { |a| a.text.strip }).to include('View Document')
    end
  end

  describe '#invitation_email' do
    it 'renders a Review and Sign button for the signer' do
      mail = described_class.invitation_email(signer)

      expect(email_button(mail, signer).map { |a| a.text.strip }).to include('Review and Sign')
    end
  end
end
