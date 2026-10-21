# frozen_string_literal: true

RSpec.describe ProcessSubmitterCompletionJob do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:template) { create(:template, account:, author: user) }
  let(:submission) { create(:submission, template:, created_by_user: user) }
  let(:submitter) { create(:submitter, submission:, uuid: SecureRandom.uuid, completed_at: Time.current) }

  before do
    create(:encrypted_config, key: EncryptedConfig::ESIGN_CERTS_KEY,
                              value: GenerateCertificate.call.transform_values(&:to_pem))

    Submissions.maybe_update_completed_at(submitter.submission)
  end

  describe '#perform' do
    it 'creates a completed submitter' do
      expect do
        described_class.new.perform('submitter_id' => submitter.id)
      end.to change(CompletedSubmitter, :count).by(1)

      completed_submitter = CompletedSubmitter.last
      submitter.reload

      expect(completed_submitter.submitter_id).to eq(submitter.id)
      expect(completed_submitter.submission_id).to eq(submitter.submission_id)
      expect(completed_submitter.account_id).to eq(submitter.submission.account_id)
      expect(completed_submitter.template_id).to eq(submitter.submission.template_id)
      expect(completed_submitter.source).to eq(submitter.submission.source)
    end

    it 'creates a completed document' do
      expect do
        described_class.new.perform('submitter_id' => submitter.id)
      end.to change(CompletedDocument, :count).by(1)

      completed_document = CompletedDocument.last

      expect(completed_document.submitter_id).to eq(submitter.id)
      expect(completed_document.sha256).to be_present
      expect(completed_document.sha256).to eq(submitter.documents.first.metadata['sha256'])
    end

    it 'raises an error if the submitter is not found' do
      expect do
        described_class.new.perform('submitter_id' => 'invalid_id')
      end.to raise_error(ActiveRecord::RecordNotFound)
    end

    context 'with Paperless-ngx and Twenty CRM configured' do
      let(:second_party) { {} }
      let(:second_completed_at) { nil }
      let(:template) do
        create(:template, submitter_count: 2, account:, author: user).tap do |t|
          t.update!(submitters: [t.submitters.first, t.submitters.second.merge(second_party)])
        end
      end
      let(:submission) do
        create(:submission, template:, created_by_user: user).tap do |s|
          create(:submitter, submission: s, uuid: template.submitters.second['uuid'], completed_at: second_completed_at)
        end
      end
      let(:submitter) do
        create(:submitter, submission:, uuid: template.submitters.first['uuid'], completed_at: Time.current)
      end
      let(:integration_job_args) { [{ 'submission_id' => submission.id }] }

      before do
        allow(Submissions::UploadToPaperless).to receive(:configured?).and_return(true)
        allow(Submissions::UploadToTwenty).to receive(:configured?).and_return(true)
      end

      context 'when the last signer completes' do
        let(:second_completed_at) { 1.hour.ago }

        it 'enqueues each upload job once' do
          described_class.new.perform('submitter_id' => submitter.id)

          expect(UploadToPaperlessJob.jobs.pluck('args')).to eq([integration_job_args])
          expect(UploadToTwentyJob.jobs.pluck('args')).to eq([integration_job_args])
        end
      end

      context 'when the other party is a pending viewer' do
        let(:second_party) { { 'is_viewer' => true } }

        it 'enqueues each upload job once' do
          described_class.new.perform('submitter_id' => submitter.id)

          expect(UploadToPaperlessJob.jobs.pluck('args')).to eq([integration_job_args])
          expect(UploadToTwentyJob.jobs.pluck('args')).to eq([integration_job_args])
        end
      end

      context 'when another required signer is still pending' do
        it 'does not enqueue the upload jobs' do
          described_class.new.perform('submitter_id' => submitter.id)

          expect(UploadToPaperlessJob.jobs).to be_empty
          expect(UploadToTwentyJob.jobs).to be_empty
        end
      end
    end
  end
end
