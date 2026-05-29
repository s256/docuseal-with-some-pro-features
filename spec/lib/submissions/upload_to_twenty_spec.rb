# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Submissions::UploadToTwenty do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:template) { create(:template, account:, author: user, name: 'Employment Contract') }
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
  end

  describe '.configured?' do
    context 'when all env vars are set' do
      it 'returns true' do
        expect(described_class.configured?).to be true
      end
    end

    context 'when TWENTY_CRM_URL is missing' do
      before { allow(ENV).to receive(:[]).with('TWENTY_CRM_URL').and_return(nil) }

      it 'returns false' do
        expect(described_class.configured?).to be false
      end
    end

    context 'when TWENTY_CRM_API_KEY is missing' do
      before { allow(ENV).to receive(:[]).with('TWENTY_CRM_API_KEY').and_return(nil) }

      it 'returns false' do
        expect(described_class.configured?).to be false
      end
    end

    context 'when TWENTY_CRM_FILE_FIELD_METADATA_ID is missing' do
      before { allow(ENV).to receive(:[]).with('TWENTY_CRM_FILE_FIELD_METADATA_ID').and_return(nil) }

      it 'returns false' do
        expect(described_class.configured?).to be false
      end
    end
  end

  describe '.health_check' do
    context 'when not configured' do
      before do
        allow(ENV).to receive(:[]).with('TWENTY_CRM_URL').and_return(nil)
        allow(ENV).to receive(:[]).with('TWENTY_CRM_API_KEY').and_return(nil)
        allow(ENV).to receive(:[]).with('TWENTY_CRM_FILE_FIELD_METADATA_ID').and_return(nil)
      end

      it 'returns configured false with no error' do
        result = described_class.health_check

        expect(result).to eq(configured: false, reachable: false, url: nil, error: nil)
      end
    end

    context 'when configured and reachable' do
      before do
        stub_request(:get, %r{#{twenty_url}/rest/companies})
          .to_return(status: 200, body: '{"data": []}')
      end

      it 'returns configured and reachable with the URL' do
        result = described_class.health_check

        expect(result).to eq(configured: true, reachable: true, url: twenty_url, error: nil)
      end
    end

    context 'when configured but server returns error' do
      before do
        stub_request(:get, %r{#{twenty_url}/rest/companies})
          .to_return(status: 401, body: '{"error": "Unauthorized"}')
      end

      it 'returns configured but unreachable with HTTP status error' do
        result = described_class.health_check

        expect(result).to eq(configured: true, reachable: false, url: twenty_url, error: 'HTTP 401')
      end
    end

    context 'when configured but connection fails' do
      before do
        stub_request(:get, %r{#{twenty_url}/rest/companies})
          .to_raise(Faraday::ConnectionFailed.new('Connection refused'))
      end

      it 'returns configured but unreachable with connection error' do
        result = described_class.health_check

        expect(result).to eq(configured: true, reachable: false, url: twenty_url, error: 'Connection refused')
      end
    end
  end

  describe '.call' do
    let(:file_id) { 'file-uuid-123' }
    let(:attachment_id) { 'attachment-uuid-456' }

    before do
      upload_response = { data: { uploadFilesFieldFile: { id: file_id, url: 'https://cdn.example.com/file.pdf' } } }
      stub_request(:post, "#{twenty_url}/metadata")
        .to_return(status: 200, body: upload_response.to_json)

      attach_response = { data: { createAttachment: { id: attachment_id } } }
      stub_request(:post, "#{twenty_url}/rest/attachments")
        .to_return(status: 201, body: attach_response.to_json)
    end

    context 'when submitter has twenty_company_id in metadata' do
      before do
        submission.submitters.first.update!(metadata: { 'twenty_company_id' => company_id })

        blob = ActiveStorage::Blob.create_and_upload!(
          io: Rails.root.join('spec/fixtures/sample-document.pdf').open,
          filename: 'combined-result.pdf',
          content_type: 'application/pdf'
        )
        ActiveStorage::Attachment.create!(blob:, name: 'combined_document', record: submission)
      end

      it 'uploads the document and creates attachment linked to the company' do
        result = described_class.call(submission)

        expect(WebMock).to have_requested(:post, "#{twenty_url}/metadata")
          .with(headers: { 'Authorization' => "Bearer #{twenty_api_key}" })
        expect(WebMock).to(have_requested(:post, "#{twenty_url}/rest/attachments")
          .with { |req| JSON.parse(req.body)['targetCompanyId'] == company_id })
        expect(result).to include(attachment_id)
      end
    end

    context 'when no submitter has twenty_company_id metadata' do
      before do
        blob = ActiveStorage::Blob.create_and_upload!(
          io: Rails.root.join('spec/fixtures/sample-document.pdf').open,
          filename: 'combined-result.pdf',
          content_type: 'application/pdf'
        )
        ActiveStorage::Attachment.create!(blob:, name: 'combined_document', record: submission)
      end

      it 'skips upload and returns nil' do
        result = described_class.call(submission)

        expect(result).to be_nil
        expect(WebMock).not_to have_requested(:post, "#{twenty_url}/metadata")
        expect(WebMock).not_to have_requested(:post, "#{twenty_url}/rest/attachments")
      end
    end

    context 'when twenty_company_id is not a valid UUID' do
      before do
        submission.submitters.first.update!(metadata: { 'twenty_company_id' => 'not-a-uuid' })

        blob = ActiveStorage::Blob.create_and_upload!(
          io: Rails.root.join('spec/fixtures/sample-document.pdf').open,
          filename: 'combined-result.pdf',
          content_type: 'application/pdf'
        )
        ActiveStorage::Attachment.create!(blob:, name: 'combined_document', record: submission)
      end

      it 'rejects the invalid ID and skips upload' do
        result = described_class.call(submission)

        expect(result).to be_nil
        expect(WebMock).not_to have_requested(:post, "#{twenty_url}/metadata")
      end
    end

    context 'when second submitter has the company ID' do
      before do
        submission.submitters.last.update!(metadata: { 'twenty_company_id' => company_id })

        blob = ActiveStorage::Blob.create_and_upload!(
          io: Rails.root.join('spec/fixtures/sample-document.pdf').open,
          filename: 'combined-result.pdf',
          content_type: 'application/pdf'
        )
        ActiveStorage::Attachment.create!(blob:, name: 'combined_document', record: submission)
      end

      it 'finds the company ID from any submitter' do
        result = described_class.call(submission)

        expect(WebMock).to(have_requested(:post, "#{twenty_url}/rest/attachments")
          .with { |req| JSON.parse(req.body)['targetCompanyId'] == company_id })
        expect(result).to be_present
      end
    end

    context 'when submission has both combined document and audit trail' do
      before do
        submission.submitters.first.update!(metadata: { 'twenty_company_id' => company_id })

        combined_blob = ActiveStorage::Blob.create_and_upload!(
          io: Rails.root.join('spec/fixtures/sample-document.pdf').open,
          filename: 'combined-result.pdf',
          content_type: 'application/pdf'
        )
        ActiveStorage::Attachment.create!(blob: combined_blob, name: 'combined_document', record: submission)

        audit_blob = ActiveStorage::Blob.create_and_upload!(
          io: Rails.root.join('spec/fixtures/sample-document.pdf').open,
          filename: 'audit-trail.pdf',
          content_type: 'application/pdf'
        )
        ActiveStorage::Attachment.create!(blob: audit_blob, name: 'audit_trail', record: submission)
      end

      it 'uploads both documents' do
        described_class.call(submission)

        expect(WebMock).to have_requested(:post, "#{twenty_url}/metadata").twice
        expect(WebMock).to have_requested(:post, "#{twenty_url}/rest/attachments").twice
      end
    end

    context 'when env vars are not configured' do
      before do
        allow(ENV).to receive(:[]).with('TWENTY_CRM_URL').and_return(nil)
        allow(ENV).to receive(:[]).with('TWENTY_CRM_API_KEY').and_return(nil)
        allow(ENV).to receive(:[]).with('TWENTY_CRM_FILE_FIELD_METADATA_ID').and_return(nil)
      end

      it 'does nothing and returns nil' do
        result = described_class.call(submission)

        expect(result).to be_nil
        expect(WebMock).not_to have_requested(:post, /twenty/)
      end
    end

    context 'when file upload fails' do
      before do
        submission.submitters.first.update!(metadata: { 'twenty_company_id' => company_id })

        stub_request(:post, "#{twenty_url}/metadata")
          .to_return(status: 500, body: 'Internal Server Error')

        blob = ActiveStorage::Blob.create_and_upload!(
          io: Rails.root.join('spec/fixtures/sample-document.pdf').open,
          filename: 'combined-result.pdf',
          content_type: 'application/pdf'
        )
        ActiveStorage::Attachment.create!(blob:, name: 'combined_document', record: submission)
      end

      it 'raises an UploadError' do
        expect { described_class.call(submission) }.to raise_error(Submissions::UploadToTwenty::UploadError)
      end
    end

    context 'when attachment creation fails' do
      before do
        submission.submitters.first.update!(metadata: { 'twenty_company_id' => company_id })

        stub_request(:post, "#{twenty_url}/rest/attachments")
          .to_return(status: 422, body: '{"error": "Invalid target"}')

        blob = ActiveStorage::Blob.create_and_upload!(
          io: Rails.root.join('spec/fixtures/sample-document.pdf').open,
          filename: 'combined-result.pdf',
          content_type: 'application/pdf'
        )
        ActiveStorage::Attachment.create!(blob:, name: 'combined_document', record: submission)
      end

      it 'raises an UploadError' do
        expect { described_class.call(submission) }.to raise_error(Submissions::UploadToTwenty::UploadError)
      end
    end
  end
end
