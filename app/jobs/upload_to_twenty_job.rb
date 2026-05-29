# frozen_string_literal: true

class UploadToTwentyJob
  include Sidekiq::Job

  sidekiq_options queue: :integrations

  MAX_ATTEMPTS = 10

  def perform(params = {})
    return unless Submissions::UploadToTwenty.configured?

    submission = Submission.find_by(id: params['submission_id'])

    return unless submission

    attempt = params['attempt'].to_i

    Rails.logger.info("[Twenty CRM] Uploading documents for submission #{submission.id}")

    results = Submissions::UploadToTwenty.call(submission)

    if results
      Rails.logger.info("[Twenty CRM] Upload complete for submission #{submission.id}: " \
                        "#{results.size} document(s)")
    end
  rescue Submissions::UploadToTwenty::UploadError, Faraday::Error => e
    return if attempt >= MAX_ATTEMPTS

    Rails.logger.warn("[Twenty CRM] Upload failed (attempt #{attempt}): #{e.message}")

    UploadToTwentyJob.perform_in(
      (2**attempt).minutes,
      'submission_id' => params['submission_id'],
      'attempt' => attempt + 1
    )
  end
end
