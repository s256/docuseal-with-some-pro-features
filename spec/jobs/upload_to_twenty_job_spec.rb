# frozen_string_literal: true

require 'rails_helper'

RSpec.describe UploadToTwentyJob do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:template) { create(:template, account:, author: user) }
  let(:submission) { create(:submission, :with_submitters, template:, created_by_user: user) }

  let(:twenty_url) { 'https://twenty.example.com' }
  let(:twenty_api_key) { 'test-api-key-abc123' }
  let(:twenty_field_metadata_id) { 'da73c92c-79e4-43d4-9a00-6ff2f37980c0' }
  let(:company_id) { '550e8400-e29b-41d4-a716-446655440000' }

  before do
    submission.submitters.each_with_index do |submitter, i|
      submitter.update!(completed_at: i.hours.ago, name: "Signer #{i + 1}", email: "signer#{i + 1}@acme.com")
    end

    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('TWENTY_CRM_URL').and_return(twenty_url)
    allow(ENV).to receive(:[]).with('TWENTY_CRM_API_KEY').and_return(twenty_api_key)
    allow(ENV).to receive(:[]).with('TWENTY_CRM_FILE_FIELD_METADATA_ID').and_return(twenty_field_metadata_id)

    submission.submitters.first.update!(metadata: { 'twenty_company_id' => company_id })

    upload_url = "#{twenty_url}/files/direct-upload/file-123?token=signed"
    create_response = { data: { createFileUpload: { fileId: 'file-123', uploadUrl: upload_url,
                                                    contentType: 'application/pdf' } } }
    stub_request(:post, "#{twenty_url}/metadata")
      .with { |req| JSON.parse(req.body)['query'].include?('createFileUpload') }
      .to_return(status: 200, body: create_response.to_json)
    stub_request(:post, "#{twenty_url}/metadata")
      .with { |req| JSON.parse(req.body)['query'].include?('completeFileUpload') }
      .to_return(status: 200, body: { data: { completeFileUpload: { id: 'file-123' } } }.to_json)
    stub_request(:put, upload_url).to_return(status: 204)

    attach_response = { data: { createAttachment: { id: 'attachment-456' } } }
    stub_request(:post, "#{twenty_url}/rest/attachments")
      .to_return(status: 201, body: attach_response.to_json)
  end

  describe '#perform' do
    context 'when Twenty CRM is configured' do
      before do
        blob = ActiveStorage::Blob.create_and_upload!(
          io: Rails.root.join('spec/fixtures/sample-document.pdf').open,
          filename: 'combined-result.pdf',
          content_type: 'application/pdf'
        )
        ActiveStorage::Attachment.create!(blob:, name: 'combined_document', record: submission)
      end

      it 'uploads documents to Twenty CRM' do
        described_class.new.perform('submission_id' => submission.id)

        expect(WebMock).to have_requested(:post, "#{twenty_url}/metadata").at_least_once
        expect(WebMock).to have_requested(:post, "#{twenty_url}/rest/attachments").at_least_once
      end
    end

    context 'when Twenty CRM is not configured' do
      before do
        allow(ENV).to receive(:[]).with('TWENTY_CRM_URL').and_return(nil)
        allow(ENV).to receive(:[]).with('TWENTY_CRM_API_KEY').and_return(nil)
        allow(ENV).to receive(:[]).with('TWENTY_CRM_FILE_FIELD_METADATA_ID').and_return(nil)
      end

      it 'does nothing' do
        described_class.new.perform('submission_id' => submission.id)

        expect(WebMock).not_to have_requested(:post, /twenty/)
      end
    end

    context 'when submission does not exist' do
      it 'does nothing' do
        described_class.new.perform('submission_id' => -1)

        expect(WebMock).not_to have_requested(:post, /twenty/)
      end
    end

    context 'when upload fails with a retryable error' do
      before do
        stub_request(:post, "#{twenty_url}/metadata")
          .to_return(status: 500, body: 'Internal Server Error')

        blob = ActiveStorage::Blob.create_and_upload!(
          io: Rails.root.join('spec/fixtures/sample-document.pdf').open,
          filename: 'combined-result.pdf',
          content_type: 'application/pdf'
        )
        ActiveStorage::Attachment.create!(blob:, name: 'combined_document', record: submission)
      end

      it 'enqueues a retry with incremented attempt' do
        expect do
          described_class.new.perform('submission_id' => submission.id, 'attempt' => 0)
        end.to change(described_class.jobs, :size).by(1)

        args = described_class.jobs.last['args'].first
        expect(args['attempt']).to eq(1)
        expect(args['submission_id']).to eq(submission.id)
      end
    end

    context 'when max attempts is reached' do
      before do
        stub_request(:post, "#{twenty_url}/metadata")
          .to_return(status: 500, body: 'Internal Server Error')

        blob = ActiveStorage::Blob.create_and_upload!(
          io: Rails.root.join('spec/fixtures/sample-document.pdf').open,
          filename: 'combined-result.pdf',
          content_type: 'application/pdf'
        )
        ActiveStorage::Attachment.create!(blob:, name: 'combined_document', record: submission)
      end

      it 'does not enqueue another retry' do
        expect do
          described_class.new.perform('submission_id' => submission.id, 'attempt' => 11)
        end.not_to change(described_class.jobs, :size)
      end
    end
  end
end
